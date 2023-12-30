# Parses a string into a Julia type object, e.g. `Int`, `Array{Int, 2}`, etc.
function Base.parse(::Type{T}, str::AbstractString) where T<:Type
    ast = Meta.parse(str)
    v = _parse_type(ast)
    # Don't pay for the assertion if not needed (~2 μs)
    T === Type && return v
    return v::T
end

# NOTE: This pattern is a hard-coded part of types: unnamed type variables start with `#s`.
_unnamed_type_var() = Symbol("#s$(gensym())")

function _parse_type(ast; type_vars = nothing)
    if ast isa Expr && ast.head == :curly
        # If the type expression has type parameters, iterate the params, evaluating them
        # recursively, and finally construct the output type with the evaluated params.

        typ = _parse_qualified_type(ast.args[1], type_vars)
        # If any of the type parameters are unnamed type restrictions, like `<:Number`, we
        # will construct new anonymous type variables for them, and wrap the returned type
        # in a UnionAll.
        new_type_vars = Vector{TypeVar}()
        # PERF: Reuse the vector to save allocations
        for i in 2:length(ast.args)
            arg = ast.args[i]
            if arg isa Expr && arg.head === :(<:) && length(arg.args) == 1
                # Change `Vector{<:Number}` to `Vector{#s#27} where #s#27<:Number`
                type_var = TypeVar(_unnamed_type_var(), _parse_type(arg.args[1]; type_vars))
                push!(new_type_vars, type_var)
                ast.args[i] = type_var
            else
                ast.args[i] = _parse_type(ast.args[i]; type_vars)
            end
        end
        # PERF: Drop the first element, instead of args[2:end], to avoid a new sub-vector
        popfirst!(ast.args)
        body = typ{ast.args...}
        # Handle any new type vars we created
        if !isempty(new_type_vars)
            # Now work backwards through the new type vars and construct our wrapper UnionAlls:
            for type_var in reverse(new_type_vars)
                body = UnionAll(type_var, body)
            end
        end
        return body
    elseif ast isa Expr && ast.head == :where
        # Collect all the type vars
        # Keep them in order, since we need to wrap the UnionAlls in reverse order.
        new_type_vars = TypeVar[]
        type_vars = Dict{Symbol, TypeVar}()
        for i in 2:length(ast.args)
            type_var = _parse_type_var(ast.args[i], type_vars)::TypeVar
            type_vars[type_var.name] = type_var
            push!(new_type_vars, type_var)
        end
        # Then evaluate the body in the context of those type vars
        body = _parse_type(ast.args[1]; type_vars)
        # Now work backwards through the new type vars and construct our wrapper UnionAlls:
        for type_var in reverse(new_type_vars)
            body = UnionAll(type_var, body)
        end
        return body
    elseif ast isa Expr && ast.head == :call && ast.args[1] === :typeof
        return typeof(_parse_type(ast.args[2]; type_vars))
    elseif ast isa Expr && ast.head == :call
        return _parse_isbits_constructor(ast, type_vars)
    else
        return _parse_qualified_type(ast, type_vars)
    end
end
_parse_qualified_type(val, _) = val
function _parse_qualified_type(ast::Expr, type_vars)
    @assert ast.head === :(.) "Failed to parse type expression. Expected a \
            qualified type, e.g. `Base.Dict`, got: `$ast`"
    mod = _parse_qualified_type(ast.args[1], type_vars)
    value = ast.args[2]
    if value isa QuoteNode
        value = value.value
    end
    return getglobal(mod, value)
end
function _parse_qualified_type(sym::Symbol, type_vars)
    # First try to look up the symbol in the type vars
    if type_vars !== nothing
        v_if_found = get(type_vars, sym, :not_found)
        if v_if_found !== :not_found
            return v_if_found
        end
    end
    #@show type_vars
    # Otherwise, look up the symbol in Main
    getglobal(Main, sym)
end

# Parses constant isbits constructor expressions, like `Int32(10)` or `Point(0,0)`, as used in type
# parameters like `Val{10}()` or `DefaultDict{Point(0,0)}`.
function _parse_isbits_constructor(ast, type_vars)
    typ = _parse_type(ast.args[1]; type_vars)
    # PERF: Reuse the args vector when parsing the type values.
    popfirst!(ast.args)
    for i in 1:length(ast.args)
        ast.args[i] = _parse_type(ast.args[i]; type_vars)
    end
    # We use reinterpret to avoid evaluating code, which may have side effects.
    return reinterpret(typ, Tuple(ast.args))
end

_parse_type_var(ast::Symbol, _type_vars) = Core.TypeVar(ast)
function _parse_type_var(ast::Expr, type_vars)
    if ast.head === :(<:)
        return Core.TypeVar(ast.args[1], _parse_type(ast.args[2]; type_vars))
    elseif ast.head === :(>:)
        return Core.TypeVar(ast.args[2], _parse_type(ast.args[1]; type_vars))
    elseif ast.head === :comparison
        if ast.args[2] === :(<:)
            @assert ast.args[4] === :(<:) "invalid bounds in \"where\": $ast"
            return Core.TypeVar(ast.args[3], _parse_type(ast.args[1]; type_vars), _parse_type(ast.args[5]; type_vars))
        else
            @assert ast.args[2] === ast.args[4] === :(>:) "invalid bounds in \"where\": $ast"
            return Core.TypeVar(ast.args[3], _parse_type(ast.args[5]; type_vars), _parse_type(ast.args[1]; type_vars))
        end
    else
        @assert false "invalid bounds in \"where\": $ast"
    end
end
