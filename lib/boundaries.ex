defmodule Bonfire.Boundaries do
  use Bonfire.Common.Utils
  import Bonfire.Boundaries.Integration

  # alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries.Circles
  # alias Bonfire.Data.AccessControl.Grant
  alias Bonfire.Data.AccessControl.Acl
  alias Bonfire.Data.Identity.Caretaker
  alias Bonfire.Boundaries.Summary
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Boundaries.Acls
  alias Bonfire.Boundaries.Controlleds
  alias Bonfire.Boundaries.Roles
  alias Bonfire.Boundaries.Queries
  alias Pointers
  alias Bonfire.Data.AccessControl.Stereotyped
  alias Pointers.Pointer
  import Queries, only: [boundarise: 3]
  import Ecto.Query
  import EctoSparkles

  def preset_name(boundaries) when is_list(boundaries) do
    debug(boundaries, "inputted")
    # Note: only one applies, in priority from most to least restrictive
    cond do
      "admins" in boundaries ->
        "admins"

      "mentions" in boundaries ->
        "mentions"

      "local" in boundaries ->
        "local"

      "public" in boundaries ->
        "public"

      "open" in boundaries or "request" in boundaries or "invite" in boundaries or
          "visible" in boundaries ->
        boundaries

      true ->
        # debug(boundaries, "No preset boundary set")
        nil
    end
    |> debug("computed")
  end

  def preset_name(other) do
    boundaries_normalise(other)
    |> preset_name()
  end

  def boundaries_or_default(to_boundaries, opts \\ [])

  def boundaries_or_default(to_boundaries, _opts)
      when is_list(to_boundaries) and to_boundaries != [] do
    to_boundaries
  end

  def boundaries_or_default(to_boundaries, _opts)
      when is_tuple(to_boundaries) do
    [to_boundaries]
  end

  def boundaries_or_default(_, opts) do
    default_boundaries(opts)
  end

  def default_boundaries(_opts \\ []) do
    # default boundaries for new stuff
    # TODO: make default user-configurable
    [{"public", l("Public")}]
  end

  def boundaries_normalise(text) when is_binary(text) do
    text
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  def boundaries_normalise(list) when is_list(list) do
    list
  end

  def boundaries_normalise(other) do
    warn(other, "Invalid boundaries set")
    []
  end

  def list_object_acls(object, opts \\ []) do
    Controlleds.list_on_object(object, opts)
    # |> debug()
    |> Enum.map(& &1.acl)
  end

  def list_grants_on(things) do
    from(s in Summary,
      where: s.object_id in ^Types.ulids(things)
    )
    |> all_grouped_by_verb()
  end

  @doc "eg: `list_grants_on(id, [:see, :read])`"
  def list_grants_on(things, verbs) do
    from(s in Summary,
      where: s.object_id in ^Types.ulids(things)
    )
    |> filter_grants_by_verbs(verbs)
  end

  def users_grants_on(users, things) do
    query_users_grants_on(users, things)
    |> all_grouped_by_verb()
  end

  def users_grants_on(users, things, verbs) do
    query_users_grants_on(users, things)
    |> filter_grants_by_verbs(verbs)
  end

  defp query_users_grants_on(users, things) do
    from(s in Summary,
      where: s.object_id in ^Types.ulids(things),
      where: s.subject_id in ^Types.ulids(users)
    )
  end

  defp filter_grants_by_verbs(query, verbs) do
    verb_ids =
      List.wrap(verbs)
      |> Enum.map(fn
        slug when is_atom(slug) -> Verbs.get_id!(slug)
        id when is_binary(id) or is_map(id) -> ulid(id)
      end)

    verb_names =
      Enum.map(verb_ids, &Verbs.get(&1).verb)
      |> Enum.sort()

    # |> debug()

    from(s in query,
      where: s.verb_id in ^verb_ids
    )
    |> all_grouped_by_verb()
    |> Enum.filter(&(&1.verbs == verb_names))
  end

  defp all_grouped_by_verb(query) do
    query
    |> repo().all()
    |> Enum.group_by(&{&1.subject_id, &1.object_id, &1.value})
    |> for({_k, [v | _] = vs} <- ...) do
      Map.put(v, :verbs, Enum.map(vs, &Verbs.get!(&1.verb_id).verb) |> Enum.sort())
    end

    # |> Enum.map(&Map.take(&1, [:subject_id, :object_id, :verbs, :value]))
  end

  def acls_from_preset_boundary_names(presets) when is_list(presets),
    do: Enum.flat_map(presets, &acls_from_preset_boundary_names/1)

  def acls_from_preset_boundary_names(preset) do
    case preset do
      preset when is_binary(preset) ->
        acls = Config.get!(:preset_acls)[preset]

        if acls do
          acls
        else
          []
        end

      _ ->
        []
    end
  end

  def preset_boundary_from_acl(acl, object_type \\ nil)

  def preset_boundary_from_acl(
        %{verbs: verbs, __typename: Bonfire.Data.AccessControl.Acl, id: acl_id} = _summary,
        object_type
      ) do
    {Roles.preset_boundary_role_from_acl(%{verbs: verbs}),
     preset_boundary_tuple_from_acl(%Acl{id: acl_id}, object_type)}

    # |> debug("merged ACL + verbs")
  end

  def preset_boundary_from_acl(%{verbs: verbs} = _summary, _object_type) do
    Roles.preset_boundary_role_from_acl(%{verbs: verbs})
  end

  def preset_boundary_from_acl(acl, object_type) do
    preset_boundary_tuple_from_acl(acl, object_type)
  end

  def preset_boundary_tuple_from_acl(acl, object_type \\ nil)

  def preset_boundary_tuple_from_acl(acl, %{__struct__: schema} = _object),
    do: preset_boundary_tuple_from_acl(acl, schema)

  def preset_boundary_tuple_from_acl(%Acl{id: acl_id} = _acl, object_type)
      when object_type in [Bonfire.Classify.Category, :group] do
    # debug(acl)

    preset_acls = Config.get!(:preset_acls_match)

    open_acl_ids =
      preset_acls["open"]
      |> Enum.map(&Acls.get_id!/1)

    visible_acl_ids =
      preset_acls["visible"]
      |> Enum.map(&Acls.get_id!/1)

    cond do
      acl_id in visible_acl_ids -> {"visible", l("Visible")}
      acl_id in open_acl_ids -> {"open", l("Open")}
      true -> {"private", l("Private")}
    end
  end

  def preset_boundary_tuple_from_acl(%Acl{id: acl_id} = _acl, _object_type) do
    # debug(acl)

    preset_acls = Config.get!(:preset_acls_match)

    public_acl_ids = Acls.public_acl_ids(preset_acls)

    local_acl_ids = Acls.local_acl_ids(preset_acls)

    cond do
      acl_id in public_acl_ids -> {"public", l("Public")}
      acl_id in local_acl_ids -> {"local", l("Local Instance")}
      true -> {"mentions", l("Mentions")}
    end
  end

  def preset_boundary_tuple_from_acl(
        %{__typename: Bonfire.Data.AccessControl.Acl, id: acl_id} = _summary,
        object_type
      ) do
    preset_boundary_tuple_from_acl(%Acl{id: acl_id}, object_type)
  end

  def preset_boundary_tuple_from_acl(%{acl: %{id: _} = acl}, object_type),
    do: preset_boundary_tuple_from_acl(acl, object_type)

  def preset_boundary_tuple_from_acl(%{acl_id: acl}, object_type),
    do: preset_boundary_tuple_from_acl(acl, object_type)

  def preset_boundary_tuple_from_acl([acl], object_type),
    do: preset_boundary_tuple_from_acl(acl, object_type)

  def preset_boundary_tuple_from_acl(other, object_type) do
    if Types.is_ulid?(other) do
      preset_boundary_tuple_from_acl(%Acl{id: other}, object_type)
    else
      warn(other, "No boundary pattern matched")
      nil
    end
  end

  def set_boundaries(creator, object, opts)
      when is_list(opts) and is_struct(object) do
    case opts[:remove_previous_preset] do
      nil ->
        with {:ok, _pointer} <- Acls.set(object, creator, opts) do
          {:ok, :granted}
        end

      previous_preset ->
        replace_boundaries(creator, object, previous_preset, opts)
    end
  end

  def replace_boundaries(creator, object, previous_preset, opts)
      when is_list(opts) and is_struct(object) do
    with object <-
           object
           # |> repo().maybe_preload(:controlled)
           |> repo().maybe_preload(created: [:creator])
           |> repo().maybe_preload(:creator),
         :ok <-
           maybe_remove_previous_preset(
             e(object, :created, :creator, nil) || e(object, :created, :creator_id, nil) ||
               e(object, :creator, nil) || e(object, :creator_id, nil) || creator,
             object,
             previous_preset
           ),
         {:ok, _pointer} <- Acls.set(object, creator, opts) do
      {:ok, :granted}
    end
  end

  defp maybe_remove_previous_preset(creator, object, [preset]) do
    maybe_remove_previous_preset(creator, object, preset)
  end

  defp maybe_remove_previous_preset(creator, object, {preset, _description}) do
    debug(preset, "TODO")

    Acls.base_acls_from_preset(creator, preset)
    |> debug("base_acls_from_preset to remove")
    |> Bonfire.Boundaries.Controlleds.remove_acls(
      object,
      ...
    )
    |> debug("removed?")

    :ok
  end

  defp maybe_remove_previous_preset(_, _, _) do
    :ok
  end

  @doc """
  Assigns the user as the caretaker of the given object or objects,
  replacing the existing caretaker, if any.
  """
  def take_care_of!(things, user) when is_list(things) do
    repo().upsert_all(
      Caretaker,
      Enum.map(things, &%{id: Types.ulid(&1), caretaker_id: Types.ulid(user)})
    )

    # |> debug

    Enum.map(things, fn thing ->
      case thing do
        %{caretaker: _} ->
          Map.put(thing, :caretaker, %Caretaker{
            id: thing.id,
            caretaker_id: Types.ulid(user),
            caretaker: user
          })

        _ ->
          thing
      end
    end)
  end

  def take_care_of!(thing, user), do: hd(take_care_of!([thing], user))

  def user_default_boundaries() do
    Config.get!(:user_default_boundaries)
  end

  def can?(_subject, can_verbs?, %{verbs: can_verbs!, value: true} = object_boundary)
      when is_list(can_verbs!) do
    warn(object_boundary, "WIP for preloaded object_boundary")
    Enum.all?(List.wrap(can_verbs?), &Enum.member?(can_verbs!, Verbs.get(&1)[:verb]))
  end

  def can?(circle_name, verbs, object) when is_atom(circle_name) do
    # lookup if a built-in circle (eg. local users) has permission (note that some circle members may NOT have permission if they're also in another circle with negative permissions)
    can?([current_user: Bonfire.Boundaries.Circles.get_id(circle_name)], verbs, object)
  end

  def can?(subject, verbs, object)
      when is_map(object) or is_binary(object) or is_list(object) do
    debug(object, "check object")
    current_user = current_user(subject)
    current_user_id = ulid(current_user)

    creator_id =
      e(object, :created, :creator_id, nil) || e(object, :created, :creator, :id, nil) ||
        e(object, :creator_id, nil) || e(object, :creator, :id, nil)

    case (not is_nil(current_user_id) and creator_id == current_user_id) or
           pointer_permitted?(object,
             current_user: current_user,
             current_account: current_account(subject),
             verbs: verbs,
             ids_only: true
           ) do
      true ->
        true

      %{id: _} ->
        true

      other ->
        debug(verbs, "no permission to")
        debug(other)
        false
    end
  end

  def can?(_subject, _verbs, object)
      when is_nil(object) or object in [:skip, :skip_boundary_check, :loading] do
    debug("no object or boundary data")
    nil
  end

  def can?(subject, verbs, :instance) do
    # cache needed for eg. for extension page
    key =
      "can:#{ulid(current_user(subject) || current_account(subject))}:#{inspect(verbs)}:instance"

    with :not_set <- Process.get(key, :not_set) |> debug("from cache?") do
      do_can_instance(subject, verbs, key)
    end
  end

  def can?(_subject, _verbs, object) do
    warn(object, "no object or boundary data")
    nil
  end

  defp do_can_instance(subject, verbs, key) do
    val =
      can?(subject, verbs, Bonfire.Boundaries.Fixtures.instance_acl())
      |> debug("put in cache")

    Process.put(key, val)
    val
  end

  def pointer_permitted?(item, opts) do
    case ulid(item) do
      id when is_binary(id) ->
        load_query(id, e(opts, :ids_only, nil), opts ++ [limit: 1])
        |> repo().exists?()

      _ ->
        error(
          item,
          "Expected an object or ULID ID, could not check boundaries"
        )

        nil
    end
  end

  def load_pointer(item, opts) do
    case ulid(item) do
      id when is_binary(id) ->
        load_query(id, e(opts, :ids_only, nil), opts ++ [limit: 1])
        |> repo().one()

      _ ->
        error(
          item,
          "Expected an object or ULID ID, could not check boundaries"
        )

        nil
    end
  end

  @doc """
  Loads binaries according to boundaries (which are assumed to be ULID pointer IDs).
  Lists which are iterated and return a [sub]list with only permitted pointers.
  """
  def load_pointers(items, opts) do
    # debug(items, "items")
    case ulid(items) do
      [] ->
        []

      nil ->
        []

      ids ->
        load_query(ids, e(opts, :ids_only, nil), opts)
        |> repo().many()
    end
  end

  defp load_query(ids, true, opts) do
    load_query(ids, nil, opts)
    |> select([main], [:id])
  end

  defp load_query(ids, _, opts) do
    (opts[:from] || Pointers.query_base(if opts[:include_deleted], do: :include_deleted))
    |> where([p], p.id in ^List.wrap(ids))
    |> boundarise(main_object.id, opts)
  end

  def find_caretaker_stereotypes(caretaker, stereotypes, from \\ Pointer)

  def find_caretaker_stereotypes(caretaker, stereotypes, from) do
    find_caretaker_stereotypes_q(caretaker, stereotypes, from)
    |> repo().all()

    # |> debug("stereotype acls")
  end

  def find_caretaker_stereotype(caretaker, stereotype, from) do
    find_caretaker_stereotypes_q(caretaker, stereotype, from)
    |> repo().one()

    # |> debug("stereotype acls")
  end

  def find_caretaker_stereotypes_q(caretaker, stereotypes, from) do
    from(a in from,
      join: c in Caretaker,
      on: a.id == c.id and c.caretaker_id == ^ulid!(caretaker),
      join: s in Stereotyped,
      on: a.id == s.id and s.stereotype_id in ^ulids(stereotypes),
      preload: [caretaker: c, stereotyped: s]
    )

    # |> debug("stereotype acls")
  end
end
