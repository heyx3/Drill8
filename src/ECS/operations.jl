World() = World(
    Vector{Entity}(),
    @f32(0), @f32(0), @f32(1),

    Dict{Entity, Dict{Type{<:AbstractComponent}, Set{AbstractComponent}}}(),
    Dict{Type{<:AbstractComponent}, Set{Entity}}(),
    Dict{Type{<:AbstractComponent}, Int}(),

    Vector{AbstractComponent}(),
    Set{Type{<:AbstractComponent}}()
)

export World


##   Managing Entities   ##

function add_entity(world::World)::Entity
    e = Entity(world, Vector{AbstractComponent}())

    # Register the entity with various data structures.
    push!(world.entities, e)
    world.component_lookup[e] = Dict{Type{<:AbstractComponent}, Set{AbstractComponent}}()

    return e
end
function remove_entity(world::World, e::Entity)
    # First remove all components so they have a chance to clean up,
    #    and so the global lookup tables are updated.
    empty!(world.buffer_entity_components)
    append!(world.buffer_entity_components, e.components)
    for i in length(world.buffer_entity_components):-1:1
        remove_component(e.components[i], e,
                         component_idx=i,
                         entity_is_dying=true)
    end

    # Next remove the entity itself.
    deleteat!(world.entities,
              findfirst(e2 -> e2==e, world.entities))
    delete!(world.component_lookup, e)
end

export add_entity, remove_entity


##   Managing components   ##

"
Returns a tuple of the component type, its parent type, etc.
   up to (but not including) `AbstractComponent`
"
function get_component_types(::Type{T})::Tuple{Vararg{Type}} where {T<:AbstractComponent}
    if T == AbstractComponent
        return ()
    elseif supertype(T) == AbstractComponent
        return (T, )
    else
        return (T, @inline(get_component_types(supertype(T)))...)
    end
end

"
Any other components that are required by the new component will be added first,
    if not in the entity already.
"
function add_component(::Type{T}, e::Entity,
                       args...
                       ;
                       # Internal parameter -- do not use.
                       # Ignores certain elements of `require_components()`
                       #    that are currently in the process of being added already,
                       #    to prevent an infinite loop from components requiring each other.
                       ignore_requirements::Optional{Set{Type{<:AbstractComponent}}} = nothing,

                       kw_args...
                      )::T where {T<:AbstractComponent}
    world::World = e.world

    # Check that this operation is valid.
    @ecs_assert(isstructtype(T) && ismutabletype(T),
                "Component type should be a mutable struct: ", T)
    if !allow_multiple(T)
        @bp_check(!has_component(e, T), "Entity already has a ", T, " attached to it")
    end

    # Add any required components that are missing.
    # Ignore ones that are already being initialized,
    #    in the case where we're inside one of these dependent 'add_component()' calls.
    new_ignore_requirements = if exists(ignore_requirements)
        ignore_requirements
    else
        empty!(world.buffer_ignore_requirements)
        world.buffer_ignore_requirements
    end
    push!(new_ignore_requirements, T)
    for required_T in require_components(T)
        if !in(required_T, new_ignore_requirements) && !has_component(e, required_T)
            add_component(required_T, e; ignore_requirements = new_ignore_requirements)
            # required_T will have been added to 'new_ignore_requirements' by the recursive call
        end
    end

    # Finally, construct the desired component and add it to all the lookups.
    component::T = create_component(T, e, args...; kw_args...)
    push!(e.components, component)
    for super_T in get_component_types(T)
        push!(get!(() -> Set{AbstractComponent}(),
                   world.component_lookup[e], super_T),
              component)
        push!(get!(() -> Set{_Entity{World}}(),
                   world.entity_lookup, super_T),
              e)
        world.component_counts[super_T] = get(world.component_counts, super_T, 0) + 1
    end

    return component
end
"
This is allowed even if the component is required by another one.
It's up to you to make sure your components either handle that or avoid that!

NOTE: the named keywords are for internal use; do not use them.
"
function remove_component(c::AbstractComponent, e::Entity
                          ;
                          # Internal optimization hints. Do not use.
                          component_idx::Int = 0,
                          entity_is_dying::Bool = false)
    @ecs_assert(c in e.components, "Can't remove a nonexistent component")
    if component_idx < 1
        component_idx = findfirst(c2 -> c2==c, e.components)
    end

    deleteat!(e.components, component_idx)

    # Remove the component from global lookups.
    T = typeof(c)
    lookup_entity_per_type = e.world.component_lookup[e]
    for super_T in get_component_types(T)
        component_set = lookup_entity_per_type[super_T]
        @ecs_assert(c in component_set)
        delete!(component_set, c)

        if isempty(component_set)
            if !entity_is_dying # If the owning entity is dying, this whole lookup is dead anyway
                delete!(lookup_entity_per_type, super_T)
            end
            delete!(e.world.entity_lookup[super_T], e)
        end

        n_components_in_world = e.world.component_counts[super_T]
        n_components_in_world -= 1
        if n_components_in_world > 0
            e.world.component_counts[super_T] = n_components_in_world
        else
            delete!(e.world.component_counts, super_T)
        end
    end

    # Let it know about the destruction.
    destroy_component(c, e, entity_is_dying)

    return nothing
end

export get_component_types, add_component, remove_component


##   Querying components   ##

const EMPTY_ENTITY_COMPONENT_LOOKUP = Dict{Type{<:AbstractComponent}, Set{AbstractComponent}}()
const EMPTY_COMPONENT_SET = Set{AbstractComponent}()
const EMPTY_ENTITY_SET = Set{Entity}()

function has_component(e::Entity, T::Type{<:AbstractComponent})::Bool
    relevant_entities = get(e.world.entity_lookup, T, EMPTY_ENTITY_SET)
    return e in relevant_entities
end

"Throws an error if there is more than one of the given type of component for the given entity"
function get_component(e::Entity, T::Type{<:AbstractComponent})::Optional{T}
    lookup = e.world.component_lookup[e]
    if haskey(lookup, T)
        components = lookup[T]
        if isempty(components)
            return nothing
        elseif length(components) > 1
            error("More than one ", T, " on entity")
        else
            return first(components)
        end
    else
        return nothing
    end
end
"Gets an iterator of all instances of the given component attached to the given entity"
function get_components(e::Entity, T::Type{<:AbstractComponent})
    @ecs_assert(isempty(EMPTY_ENTITY_COMPONENT_LOOKUP),
                "Somebody modified the return value of 'get_components()'!")
    per_component_lookup = get(e.world.component_lookup, e,
                               EMPTY_ENTITY_COMPONENT_LOOKUP)

    @ecs_assert(isempty(EMPTY_COMPONENT_SET),
                "Somebody modified the return value of 'get_components()'!")
    return get(per_component_lookup, T, EMPTY_COMPONENT_SET)::Set{AbstractComponent}
end

"
Gets a singleton component, assumed to be the only one of its kind.
Returns its owning entity as well.
"
function get_component(w::World, T::Type{<:AbstractComponent})::Optional{Tuple{T, Entity}}
    all_instances = get_components(w, T)

    # Get the first instance.
    iter_first = iterate(all_instances)
    if isnothing(iter_first)
        return nothing
    end

    # Double-check that there's no second one.
    (result, iter_state) = iter_first
    iter_second = iterate(all_instances, iter_state)
    @bp_check(isnothing(iter_second), "Found more than one ", T)

    @ecs_assert(result isa Tuple{T, Entity}, "Lookup provided us with a ",
                    typeof(result), " instead of a Tuple{", T, ", Entity}")
    return result::Tuple{T, Entity}
end
"
Gets an iterator of all instances of the given component in the entire world.
Each element is a `Tuple{T, Entity}`.
"
function get_components(w::World, T::Type{<:AbstractComponent})
    #TODO: Instead of an iterator that could break after entity modification, use an array of pooled memory. Wrap the user code in a 'do' block to enforce that the array is temporary
    @ecs_assert(isempty(EMPTY_ENTITY_SET), "Somebody modified 'EMPTY_ENTITY_SET'")

    relevant_entities = get(w.entity_lookup, T, EMPTY_ENTITY_SET)
    relevant_type_lookups = ((e, w.component_lookup[e]) for e in relevant_entities)
    instances_per_entity = ((e, get(lookup, T, EMPTY_COMPONENT_SET)) for (e, lookup) in relevant_type_lookups)
    return Iterators.flatten(zip(instances, Iterators.repeated(e)) for (e, instances) in instances_per_entity)
end

export has_component, get_component, get_components