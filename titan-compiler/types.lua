local typedecl = require 'titan-compiler.typedecl'

local types = typedecl("Type", {
    Types = {
        Invalid     = {},
        Nil         = {},
        Boolean     = {},
        Integer     = {},
        Float       = {},
        String      = {},
        Value       = {},
        Function    = {"params", "rettypes", "vararg"},
        Array       = {"elem"},
        InitList    = {"elems"},
        Record      = {"name", "fields"},
        Type        = {"type"},
    }
})

function types.is_basic(t)
    local tag = t._tag
    return tag == "Type.Nil" or
           tag == "Type.Boolean" or
           tag == "Type.Integer" or
           tag == "Type.Float" or
           tag == "Type.String" or
           tag == "Type.Value"
end

function types.is_gc(t)
    local tag = t._tag
    return tag == "Type.String" or
           tag == "Type.Value" or
           tag == "Type.Function" or
           tag == "Type.Array" or
           tag == "Type.Record"
end

-- XXX this should be inside typedecl call
-- constructors shouldn't do more than initalize members
-- XXX this should not be a type. This makes it possible to
-- construct nonsense things like a function type that returns
-- a module type
function types.Module(modname, members)
    return { _tag = "Type.Module", name = modname,
        prefix = modname:gsub("[%-.]", "_") .. "_",
        file = modname:gsub("[.]", "/") .. ".so",
        members = members }
end

--- Check if two pointer types are different and can be coerced.
local function can_coerce_pointer(source, target)
    if types.equals(source, target) then
        return false
    elseif types.has_tag(target.type, "Nil") then
        -- all pointers are convertible to void*
        if types.equals(source, types.String) then
            return true
        elseif types.equals(source, types.Nil) then
            return true
        elseif types.has_tag(source, "Pointer") then
            return true
        end
    end
    return false
end

function types.explicitly_coerceable(source, target)
    return (types.equals(target, types.String) and (types.has_tag(source, "Pointer") and (types.has_tag(source.type, "Nil"))))
end

function types.coerceable(source, target)
    return (target._tag == "Type.Pointer" and
            can_coerce_pointer(source, target)) or

           (source._tag == "Type.Integer" and
            target._tag == "Type.Float") or

           (source._tag == "Type.Float" and
            target._tag == "Type.Integer") or

           (target._tag == "Type.Boolean" and
            source._tag ~= "Type.Boolean") or

           (target._tag == "Type.Value" and
            source._tag ~= "Type.Value") or

           (source._tag == "Type.Value" and
            target._tag ~= "Type.Value")
end

-- The type consistency relation, a-la gradual typing
function types.compatible(t1, t2)
    if types.equals(t1, t2) then
        return true
    elseif t1._tag == "Type.Typedef" then
        return types.compatible(t1._type, t2)
    elseif t2._tag == "Type.Typedef" then
        return types.compatible(t1, t2._type)
    elseif types.equals(t2, types.String) and (types.has_tag(t1, "Pointer") and (types.has_tag(t1.type, "Nil"))) then
        return true
    elseif t1._tag == "Type.Value" or t2._tag == "Type.Value" then
        return true
    elseif t1._tag == "Type.Array" and t2._tag == "Type.Array" then
        return types.compatible(t1.elem, t2.elem)
    elseif t1._tag == "Type.Function" and t2._tag == "Type.Function" then
        if #t1.params ~= #t2.params then
            return false
        end

        for i = 1, #t1.params do
            if not types.compatible(t1.params[i], t2.params[i]) then
                return false
            end
        end

        if #t1.rettypes ~= #t2.rettypes then
            return false
        end

        for i = 1, #t1.rettypes do
            if not types.compatible(t1.rettypes[i], t2.rettypes[i]) then
                return false
            end
        end

        return true
    else
        return false
    end
end

function types.equals(t1, t2)
    local tag1, tag2 = t1._tag, t2._tag
    if tag1 == "Type.Array" and tag2 == "Type.Array" then
        return types.equals(t1.elem, t2.elem)
    elseif tag1 == "Type.Pointer" and tag2 == "Type.Pointer" then
        return types.equals(t1.type, t2.type)
    elseif tag1 == "Type.Typedef" and tag2 == "Type.Typedef" then
        return t1.name == t2.name
    elseif tag1 == "Type.Function" and tag2 == "Type.Function" then
        if #t1.params ~= #t2.params then
            return false
        end

        for i = 1, #t1.params do
            if not types.equals(t1.params[i], t2.params[i]) then
                return false
            end
        end

        if #t1.rettypes ~= #t2.rettypes then
            return false
        end

        for i = 1, #t1.rettypes do
            if not types.equals(t1.rettypes[i], t2.rettypes[i]) then
                return false
            end
        end

        return true
    elseif tag1 == tag2 then
        return true
    else
        return false
    end
end

function types.tostring(t)
    local tag = t._tag
    if     tag == "Type.Integer"     then return "integer"
    elseif tag == "Type.Boolean"     then return "boolean"
    elseif tag == "Type.String"      then return "string"
    elseif tag == "Type.Nil"         then return "nil"
    elseif tag == "Type.Float"       then return "float"
    elseif tag == "Type.Value"       then return "value"
    elseif tag == "Type.Invalid"     then return "invalid type"
    elseif tag == "Type.Array" then
        return "{ " .. types.tostring(t.elem) .. " }"
    elseif tag == "Type.Pointer" then
        if t.type == types.Nil then
            return "void pointer"
        else
            return "pointer to " .. types.tostring(t.type)
        end
    elseif tag == "Type.Typedef" then
        return t.name
    elseif tag == "Type.Function" then
        return "function" -- TODO implement
    elseif tag == "Type.Array" then
        return "{ " .. types.tostring(t.elem) .. " }"
    elseif tag == "Type.InitList" then
        return "initlist" -- TODO implement
    elseif tag == "Type.Record" then
        return t.name
    elseif tag == "Type.Type" then
        return "type" -- TODO remove
    else
        error("impossible")
    end
end

-- Builds a type for the module from the types of its public members
--   ast: AST for the module
--   returns "Type.Module" type
function types.makemoduletype(modname, ast)
    local members = {}
    for _, tlnode in ipairs(ast) do
        if tlnode._tag ~= "Ast.TopLevelImport" and not tlnode.islocal and not tlnode._ignore then
            local tag = tlnode._tag
            if tag == "Ast.TopLevelFunc" then
                members[tlnode.name] = tlnode._type
            elseif tag == "Ast.TopLevelVar" then
                members[tlnode.decl.name] = tlnode._type
            end
        end
    end
    return types.Module(modname, members)
end

function types.serialize(t)
    local tag = t._tag
    if tag == "Type.Array" then
        return "Array(" ..types.serialize(t.elem) .. ")"
    elseif tag == "Type.Module" then
        local members = {}
        for name, member in pairs(t.members) do
            table.insert(members, name .. " = " .. types.serialize(member))
        end
        return "Module(" ..
            "'" .. t.name .. "'" .. "," ..
            "{" .. table.concat(members, ",") .. "}" ..
            ")"
    elseif tag == "Type.Function" then
        local ptypes = {}
        for _, pt in ipairs(t.params) do
            table.insert(ptypes, types.serialize(pt))
        end
        local rettypes = {}
        for _, rt in ipairs(t.rettypes) do
            table.insert(rettypes, types.serialize(rt))
        end
        return "Function(" ..
            "{" .. table.concat(ptypes, ",") .. "}" .. "," ..
            "{" .. table.concat(rettypes, ",") .. "}" ..
            ")"
    else
        return tag
    end
end

return types
