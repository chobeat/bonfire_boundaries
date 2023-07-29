defmodule Bonfire.Boundaries.Acls do
  @moduledoc """
  ACLs represent fully populated access control rules that can be reused.
  Can be reused to secure multiple objects, thus exists independently of any object.

  The table doesn't have any fields of its own: 
  ```
  has_many(:grants, Grant)
  has_many(:controlled, Controlled)
  ```
  """
  use Arrows
  use Bonfire.Common.Utils
  import Bonfire.Boundaries.Integration
  import Ecto.Query
  import EctoSparkles
  import Bonfire.Boundaries.Integration
  import Bonfire.Boundaries.Queries

  alias Bonfire.Data.Identity.Named
  alias Bonfire.Data.Identity.ExtraInfo
  alias Bonfire.Data.Identity.Caretaker
  alias Bonfire.Data.AccessControl.Acl
  alias Bonfire.Data.AccessControl.Controlled
  alias Bonfire.Data.AccessControl.Grant
  alias Bonfire.Data.AccessControl.Stereotyped

  alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries
  alias Bonfire.Boundaries.Controlleds
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Boundaries.Fixtures
  alias Bonfire.Boundaries.Grants
  alias Bonfire.Boundaries.Roles
  alias Ecto.Changeset
  alias Pointers.Changesets
  alias Pointers.ULID

  def exclude_stereotypes(including_custom? \\ true)

  def exclude_stereotypes(false) do
    # don't show "others who silenced me"
    ["2HEYS11ENCEDMES0CAN0TSEEME"]
  end

  def exclude_stereotypes(_true) do
    # don't show custom per-object ACLs
    exclude_stereotypes(false) ++ ["7HECVST0MAC1F0RAN0BJECTETC"]
  end

  def default_exclude_ids(including_custom? \\ true) do
    exclude_stereotypes(including_custom?) ++
      [
        "71MAYADM1N1STERMY0WNSTVFFS",
        "0H0STEDCANTSEE0RD0ANYTH1NG",
        "1S11ENCEDTHEMS0CAN0TP1NGME"
      ]
  end

  def remote_public_acl_ids, do: ["5REM0TEPE0P1E1NTERACTREACT", "5REM0TEPE0P1E1NTERACTREP1Y"]

  def public_acl_ids(preset_acls \\ Config.get!(:preset_acls_match)),
    do:
      preset_acls["public"]
      |> Enum.map(&get_id!/1)

  def local_acl_ids(preset_acls \\ Config.get!(:preset_acls_match)),
    do:
      preset_acls["local"]
      |> Enum.map(&get_id!/1)

  # special built-in acls (eg, guest, local, activity_pub)
  def acls, do: Config.get(:acls)

  def preset_acl_ids do
    Config.get(:public_acls_on_objects, [
      :guests_may_see_read,
      :locals_may_interact,
      :locals_may_reply
    ])
    |> Enum.map(&get_id!/1)
  end

  def get(slug) when is_atom(slug), do: acls()[slug]

  def get!(slug) when is_atom(slug) do
    # || ( Bonfire.Boundaries.Fixtures.insert && get(slug) )
    get(slug) ||
      raise RuntimeError, message: "Missing default acl: #{inspect(slug)}"
  end

  def get_id(slug), do: e(acls(), slug, :id, nil)
  def get_id!(slug), do: get!(slug)[:id]

  def acl_id(:instance) do
    Bonfire.Boundaries.Fixtures.instance_acl()
  end

  def acl_id(obj) do
    ulid(obj) || get_id!(obj)
  end

  def set(object, creator, opts)
      when is_list(opts) and is_struct(object) do
    with {:ok, _pointer} <- do_set(object, creator, opts) do
      {:ok, :granted}
    end
  end

  def preview(creator, opts)
      when is_list(opts) do
    with {:error, {:ok, [%{verbs: verbs}]}} <- do_preview(creator, opts) do
      {:ok, verbs}
    else
      {:error, {:ok, []}} ->
        {:ok, []}

      other ->
        error(other)
    end
  end

  defp do_preview(creator, opts) do
    object = generate_object()

    repo().transaction(fn repo ->
      do_set(object, creator, opts)

      repo().rollback(
        {:ok,
         Bonfire.Boundaries.users_grants_on(
           opts[:preview_for_id] || Circles.get_id!(:guest),
           object
         )}
      )
    end)
  end

  defp generate_object do
    Pointers.Pointer.create(Bonfire.Data.Social.Post)
    |> Bonfire.Common.Repo.insert!()
  end

  defp do_set(object, creator, opts) do
    id = ulid(object)

    case prepare_cast(object, creator, opts) do
      {:ok, control_acls} ->
        control_acls

      {fun, control_acls} when is_function(fun) ->
        fun.(repo())

        control_acls
    end
    |> Enum.map(&Map.put(&1, :id, id))
    |> debug("insert controlled")
    |> repo().insert_all(Controlled, ..., on_conflict: :nothing)
    |> debug("inserted?")
  end

  def cast(changeset, creator, opts) do
    case prepare_cast(changeset, creator, opts) do
      {:ok, control_acls} ->
        Changesets.put_assoc(changeset, :controlled, control_acls)

      {fun, control_acls} when is_function(fun) ->
        changeset
        |> Changeset.prepare_changes(fun)
        |> Changesets.put_assoc!(:controlled, control_acls)
    end
  end

  def prepare_cast(changeset_or_obj, creator, opts) do
    opts
    |> info("opts")

    context_id = maybe_from_opts(opts, :context_id)

    {preset, control_acls} =
      case maybe_from_opts(opts, :boundary, opts) do
        {:clone, controlled_object_id} ->
          copy_acls_from_existing_object(controlled_object_id)

        ["clone_context"] when is_binary(context_id) ->
          copy_acls_from_existing_object(context_id)

        to_boundaries ->
          preset_acls_tuple(creator, to_boundaries, opts)
      end

    debug(control_acls, "preset + inputted ACLs to set")

    case custom_recipients(changeset_or_obj, preset, opts) do
      [] ->
        {:ok, control_acls}

      custom_recipients ->
        # TODO: enable using cast on existing objects by using `get_or_create_object_custom_acl(object)` to check if a custom Acl already exists?
        acl_id = ULID.generate()

        # default_role = e(opts, :role_to_grant, nil) || Config.get!([:role_to_grant, :default])

        custom_grants =
          (e(opts, :verbs_to_grant, nil) ||
             Config.get!([:verbs_to_grant, :default]))
          |> debug("default verbs_to_grant")
          |> Enum.flat_map(custom_recipients, &grant_to(&1, acl_id, ..., true, opts))
          |> debug("on-the-fly ACLs to create")

        {
          fn repo_or_changeset ->
            insert_custom_acl_and_grants(repo_or_changeset, acl_id, custom_grants)
          end,
          [%{acl_id: acl_id} | control_acls]
        }
    end
  end

  defp preset_acls_tuple(creator, to_boundaries, opts \\ []) do
    {preset, base_acls, direct_acl_ids} =
      preset_stereotypes_and_acls(
        creator,
        to_boundaries,
        opts
        |> Keyword.put_new_lazy(:universal_boundaries, fn ->
          Config.get!([:object_default_boundaries, :acls])
        end)
      )

    {preset,
     Enum.map(
       find_acls(base_acls, creator) ++ direct_acl_ids,
       &%{acl_id: &1.id}
     )}
  end

  def acls_from_preset(creator, to_boundaries, opts \\ []) do
    {preset, base_acls, direct_acl_ids} =
      preset_stereotypes_and_acls(
        creator,
        to_boundaries,
        opts
      )

    find_acls(base_acls, creator) ++ list(ids: direct_acl_ids, current_user: creator)
  end

  def grants_from_preset(creator, to_boundaries, opts \\ []) do
    {preset, base_acls, direct_acl_ids} =
      preset_stereotypes_and_acls(
        creator,
        to_boundaries,
        opts
      )

    # list(ids: direct_acl_ids, current_user: creator)
    # |> repo().maybe_preload(:grants)
    (Grants.get(base_acls)
     |> Enum.flat_map(
       &Enum.map(
         &1,
         fn {slug, role} ->
           {Circles.get(slug), role}
         end
       )
     )) ++
      (Grants.list_for_acl(direct_acl_ids, current_user: creator, skip_boundary_check: true)
       |> repo().maybe_preload(:subject)
       |> repo().maybe_preload(subject: [:named, stereotyped: [:named]])
       |> repo().maybe_preload(subject: [:profile])
       |> Grants.subject_grants()
       |> Enum.map(fn
         {_subject_id, %{subject: subject, grants: grants}} ->
           {subject, Roles.role_from_grants(grants, current_user: creator)}
       end))
  end

  defp preset_stereotypes_and_acls(creator, to_boundaries, opts \\ []) do
    {to_boundaries, preset} = to_boundaries_preset_tuple(to_boundaries)

    # add ACLs based on any boundary presets (eg. public/local/mentions)
    # + add any ACLs directly specified in input     

    {preset, base_acls(creator, preset, opts), maybe_add_direct_acl_ids(to_boundaries)}
  end

  defp to_boundaries_preset_tuple(to_boundaries) do
    to_boundaries =
      Boundaries.boundaries_normalise(to_boundaries)
      |> debug("validated to_boundaries")

    preset =
      Boundaries.preset_name(to_boundaries)
      |> debug("preset_name")

    {to_boundaries, preset}
  end

  def base_acls_from_preset(creator, preset, opts \\ []) do
    {_preset, control_acls} = preset_acls_tuple(creator, preset, opts)
    control_acls
  end

  # when the user picks a preset, this maps to a set of base acls
  defp base_acls(user, preset, opts) do
    (List.wrap(opts[:universal_boundaries]) ++
       Boundaries.acls_from_preset_boundary_names(preset))
    |> info("preset ACLs to set (based on preset #{preset}) ")
  end

  defp maybe_add_direct_acl_ids(acls) do
    ulids(acls)
    |> filter_empty([])
  end

  defp custom_recipients(changeset_or_obj, preset, opts) do
    (List.wrap(reply_to_grants(changeset_or_obj, preset, opts)) ++
       List.wrap(mentions_grants(changeset_or_obj, preset, opts)) ++
       List.wrap(maybe_custom_circles_or_users(maybe_from_opts(opts, :to_circles, []))))
    |> debug()
    |> Enum.map(fn
      {subject, role} -> {subject, role}
      subject -> {subject, nil}
    end)
    |> debug()
    |> Enum.sort_by(fn {_subject, role} -> role end, :desc)
    # |> debug()
    |> Enum.uniq_by(fn {subject, _role} -> subject end)
    # |> debug()
    |> filter_empty([])
    |> debug()
  end

  defp maybe_custom_circles_or_users(to_circles) when is_list(to_circles) or is_map(to_circles) do
    to_circles
    |> debug()
    |> Enum.map(fn
      {key, val} ->
        # with custom role 
        case ulid(key) do
          nil -> {ulid(val), key}
          subject_id -> {subject_id, val}
        end

      val ->
        ulid(val)
    end)
    |> debug()
  end

  defp maybe_custom_circles_or_users(to_circles),
    do: maybe_custom_circles_or_users(List.wrap(to_circles))

  defp reply_to_grants(changeset_or_obj, preset, _opts) do
    reply_to_creator =
      Utils.e(
        changeset_or_obj,
        :changes,
        :replied,
        :changes,
        :replying_to,
        :created,
        :creator,
        nil
      ) ||
        Utils.e(
          changeset_or_obj,
          :replied,
          :reply_to,
          :created,
          :creator,
          nil
        )

    if reply_to_creator do
      # debug(reply_to_creator, "creators of reply_to should be added to a new ACL")

      case preset do
        "public" ->
          id(reply_to_creator)

        "local" ->
          if is_local?(reply_to_creator),
            do: id(reply_to_creator),
            else: []

        _ ->
          []
      end
    else
      []
    end
  end

  defp mentions_grants(changeset_or_obj, preset, _opts) do
    mentions =
      Utils.e(changeset_or_obj, :changes, :post_content, :changes, :mentions, nil) ||
        Utils.e(changeset_or_obj, :post_content, :mentions, nil)

    if mentions && mentions != [] do
      # debug(mentions, "mentions/tags may be added to a new ACL")

      case preset do
        "public" ->
          ulid(mentions)

        "mentions" ->
          ulid(mentions)

        "local" ->
          # include only if local
          mentions
          |> Enum.filter(&is_local?/1)
          |> ulid()

        _ ->
          # do not grant to mentions by default
          []
      end
    else
      []
    end
  end

  defp find_acls(acls, user)
       when is_list(acls) and length(acls) > 0 and
              (is_binary(user) or is_map(user)) do
    acls =
      acls
      |> Enum.map(&identify/1)
      # |> info("identified")
      |> filter_empty([])
      |> Enum.group_by(&elem(&1, 0))

    globals =
      acls
      |> Map.get(:global, [])
      |> Enum.map(&elem(&1, 1))

    # |> info("globals")
    stereo =
      case Map.get(acls, :stereo, []) do
        [] ->
          []

        stereo ->
          stereo
          |> Enum.map(&elem(&1, 1).id)
          |> find_caretaker_stereotypes(user, ...)

          # |> info("stereos")
      end

    globals ++ stereo
  end

  defp find_acls(_acls, _) do
    warn("You need to provide an object creator to properly set ACLs")
    []
  end

  defp identify(name) do
    case user_default_acl(name) do
      # seems to be a global ACL
      nil ->
        {:global, get!(name)}

      # should be a user-level stereotyped ACL
      default ->
        case default[:stereotype] do
          nil ->
            raise RuntimeError,
              message: "Boundaries: Unstereotyped user acl in config: #{inspect(name)}"

          stereo ->
            {:stereo, get!(stereo)}
        end
    end
  end

  defp grant_to(subject, acl_id, default_verbs, value, opts)

  defp grant_to({subject_id, nil}, acl_id, default_verbs, value, opts),
    do: grant_to(subject_id, acl_id, default_verbs, value, opts)

  defp grant_to({subject_id, roles}, acl_id, default_verbs, value, opts) when is_list(roles) do
    Enum.flat_map(roles, &grant_to({subject_id, &1}, acl_id, default_verbs, value, opts))
  end

  defp grant_to({subject_id, role}, acl_id, _default_verbs, _value, opts) do
    with {:ok, can_verbs, cannot_verbs} <- Roles.verbs_for_role(role, opts) do
      grant_to(subject_id, acl_id, can_verbs, true, opts) ++
        grant_to(subject_id, acl_id, cannot_verbs, false, opts)
    else
      e ->
        error(e)
        []
    end
  end

  defp grant_to(user_etc, acl_id, verbs, value, opts) when is_list(verbs),
    do: Enum.flat_map(verbs, &grant_to(user_etc, acl_id, &1, value, opts))

  defp grant_to(users_etc, acl_id, verb, value, opts) when is_list(users_etc),
    do: Enum.flat_map(users_etc, &grant_to(&1, acl_id, verb, value, opts))

  defp grant_to(user_etc, acl_id, verb, value, _opts) do
    debug(user_etc)

    [
      %{
        id: ULID.generate(),
        acl_id: acl_id,
        subject_id: user_etc,
        verb_id: Verbs.get_id!(verb),
        value: value
      }
    ]
  end

  def get_object_custom_acl(object) do
    from(a in Acl,
      join: c in Controlled,
      on: a.id == c.acl_id and c.id == ^id(object),
      join: s in Stereotyped,
      on: a.id == s.id and s.stereotype_id == ^Fixtures.custom_acl(),
      preload: [stereotyped: s]
    )
    |> repo().single()

    # |> debug("custom acl")
  end

  def get_or_create_object_custom_acl(object, caretaker \\ nil) do
    case get_object_custom_acl(object) do
      {:ok, acl} ->
        {:ok, acl}

      _ ->
        with {:ok, acl} <-
               create(
                 prepare_custom_acl_maps(ULID.generate()),
                 current_user: caretaker
               ),
             {:ok, _} <- Controlleds.add_acls(object, acl) do
          {:ok, acl}
        end
    end
  end

  defp insert_custom_acl_and_grants(repo_or_changeset \\ repo(), acl_id, custom_grants)

  defp insert_custom_acl_and_grants(%Ecto.Changeset{} = changeset, acl_id, custom_grants) do
    insert_custom_acl_and_grants(changeset.repo, acl_id, custom_grants)
    changeset
  end

  defp insert_custom_acl_and_grants(repo, acl_id, custom_grants) do
    prepare_custom_acl(acl_id)
    |> repo.insert!()
    |> debug()

    repo.insert_all(Grant, custom_grants)
    |> debug()
  end

  defp prepare_custom_acl(acl_id) do
    %Acl{
      id: acl_id,
      stereotyped: %Stereotyped{id: acl_id, stereotype_id: Fixtures.custom_acl()}
    }
  end

  defp prepare_custom_acl_maps(acl_id) do
    %{
      id: acl_id,
      stereotyped: %{id: acl_id, stereotype_id: Fixtures.custom_acl()}
    }
  end

  defp copy_acls_from_existing_object(controlled_object_id) do
    {nil,
     Controlleds.list_on_object(controlled_object_id)
     |> Enum.map(&Map.take(&1, [:acl_id]))
     |> debug()}
  end

  ## invariants:

  ## * All a user's ACLs will have the user as an administrator but it
  ##   will be hidden from the user

  def create(attrs \\ %{}, opts) do
    attrs
    |> input_to_atoms()
    |> changeset(:create, ..., opts)
    |> repo().insert()
  end

  def simple_create(caretaker, name) do
    create(%{named: %{name: name}}, current_user: caretaker)
  end

  def changeset(:create, attrs, opts) do
    changeset(:create, attrs, opts, Keyword.fetch!(opts, :current_user))
  end

  defp changeset(:create, attrs, _opts, :system), do: changeset_cast(attrs)

  defp changeset(:create, attrs, opts, :instance),
    do:
      changeset(:create, attrs, opts, %{
        id: Bonfire.Boundaries.Fixtures.admin_circle()
      })

  defp changeset(:create, attrs, _opts, %{id: id}) do
    Changesets.cast(%Acl{}, %{caretaker: %{caretaker_id: id}}, [])
    |> changeset_cast(attrs)
  end

  defp changeset_cast(acl \\ %Acl{}, attrs) do
    Acl.changeset(acl, attrs)
    # |> IO.inspect(label: "cs")
    |> Changesets.cast_assoc(:named, with: &Named.changeset/2)
    |> Changesets.cast_assoc(:extra_info, with: &ExtraInfo.changeset/2)
    |> Changesets.cast_assoc(:caretaker, with: &Caretaker.changeset/2)
    |> Changesets.cast_assoc(:stereotyped)
  end

  def get_for_caretaker(id, caretaker, opts \\ []) do
    with {:ok, acl} <- repo().single(get_for_caretaker_q(id, caretaker, opts)) do
      {:ok, acl}
    else
      {:error, :not_found} ->
        if is_admin?(caretaker),
          do:
            repo().single(
              get_for_caretaker_q(
                id,
                Bonfire.Boundaries.Fixtures.admin_circle(),
                opts
              )
            ),
          else: {:error, :not_found}
    end
  end

  def get_for_caretaker_q(id, caretaker, opts \\ []) do
    list_q(opts ++ [skip_boundary_check: true])
    # |> reusable_join(:inner, [circle: circle], caretaker in assoc(circle, :caretaker), as: :caretaker)
    |> maybe_for_caretaker(id, caretaker)
  end

  defp maybe_for_caretaker(query, id, caretaker) do
    if id in built_in_ids() do
      where(query, [acl], acl.id == ^ulid!(id))
    else
      # |> reusable_join(:inner, [circle: circle], caretaker in assoc(circle, :caretaker), as: :caretaker)
      where(
        query,
        [acl, caretaker: caretaker],
        acl.id == ^ulid!(id) and caretaker.caretaker_id == ^ulid!(caretaker)
      )
    end
  end

  @doc """
  Lists ACLs we are permitted to see.
  """
  def list(opts \\ []) do
    list_q(opts)
    |> where(
      [caretaker: caretaker],
      caretaker.caretaker_id in ^[ulid(opts[:current_user]), Fixtures.admin_circle()]
    )
    |> repo().many()
  end

  def list_q(opts \\ []) do
    from(acl in Acl, as: :acl)
    # |> boundarise(acl.id, opts)
    |> proload([
      :caretaker,
      :named,
      :extra_info,
      stereotyped: {"stereotype_", [:named]}
    ])
    |> maybe_by_ids(opts[:ids])
    |> maybe_search(opts[:search])
  end

  def maybe_by_ids(query, ids) when is_binary(ids) or is_list(ids) do
    query
    |> where(
      [acl],
      acl.id in ^Types.ulids(ids)
    )
  end

  def maybe_by_ids(query, _), do: query

  def maybe_search(query, text) when is_binary(text) and text != "" do
    query
    |> where(
      [named: named, stereotype_named: stereotype_named],
      ilike(named.name, ^"#{text}%") or
        ilike(named.name, ^"% #{text}%") or
        ilike(stereotype_named.name, ^"#{text}%") or
        ilike(stereotype_named.name, ^"% #{text}%")
    )
  end

  def maybe_search(query, _), do: query

  # def list_all do
  #   from(u in Acl, as: :acl)
  #   |> proload([:named, :controlled, :stereotyped, :caretaker])
  #   |> repo().many()
  # end

  def built_in_ids do
    acls()
    |> Map.values()
    |> Enum.map(& &1.id)
  end

  def stereotype_ids do
    acls()
    |> Map.values()
    |> Enum.filter(&e(&1, :stereotype, nil))
    |> Enum.map(& &1.id)
  end

  def is_stereotyped?(%{stereotyped: %{stereotype_id: stereotype_id}} = _acl)
      when is_binary(stereotype_id) do
    true
  end

  def is_stereotyped?(_acl) do
    false
  end

  def is_stereotype?(acl) do
    # debug(acl)
    ulid(acl) in stereotype_ids()
  end

  def is_object_custom?(%{stereotyped: %{stereotype_id: stereotype_id}} = _acl)
      when is_binary(stereotype_id) do
    is_object_custom?(stereotype_id)
    |> debug(stereotype_id)
  end

  def is_object_custom?(acl) do
    id(acl) == Fixtures.custom_acl()
  end

  def list_built_ins do
    list_q(skip_boundary_check: true)
    |> where([acl], acl.id in ^built_in_ids())
    |> repo().many()
  end

  # TODO
  defp built_ins_for_dropdown do
    filter = Config.get(:acls_to_present)

    acls()
    |> Enum.filter(fn {name, _acl} -> name in filter end)
    |> Enum.map(fn {_name, acl} -> acl.id end)
  end

  def opts_for_dropdown() do
    opts_for_list() ++
      [
        extra_ids_to_include: built_ins_for_dropdown()
      ]
  end

  def opts_for_list() do
    [
      exclude_ids: default_exclude_ids()
    ]
  end

  def for_dropdown(opts) do
    list_my_with_counts(current_user(opts), opts ++ opts_for_dropdown())
  end

  @doc """
  Lists the ACLs we are the registered caretakers of that we are
  permitted to see. If any are created without permitting the
  user to see them, they will not be shown.
  """
  def list_my(user, opts \\ []), do: repo().many(list_my_q(user, opts))

  def list_my_with_counts(user, opts \\ []) do
    list_my_q(user, opts)
    |> join(
      :left,
      [acl],
      grants in subquery(
        from(g in Grant,
          group_by: g.acl_id,
          select: %{acl_id: g.acl_id, count: count()}
        )
      ),
      on: grants.acl_id == acl.id,
      as: :grants
    )
    |> join(
      :left,
      [acl],
      controlled in subquery(
        from(c in Controlled,
          group_by: c.acl_id,
          select: %{acl_id: c.acl_id, count: count()}
        )
      ),
      on: controlled.acl_id == acl.id,
      as: :controlled
    )
    |> select_merge([grants: grants, controlled: controlled], %{
      grants_count: grants.count,
      controlled_count: controlled.count
    })
    |> order_by([grants: grants, controlled: controlled],
      desc_nulls_last: controlled.count,
      desc_nulls_last: grants.count
    )
    |> repo().many()
  end

  @doc "query for `list_my`"
  def list_my_q(user, opts \\ []) do
    exclude =
      e(
        opts,
        :exclude_ids,
        exclude_stereotypes(
          e(
            opts,
            :exclude_stereotypes,
            nil
          )
        )
      )

    list_q(skip_boundary_check: true)
    |> where(
      [acl, caretaker: caretaker],
      caretaker.caretaker_id == ^ulid!(user) or
        (acl.id in ^e(opts, :extra_ids_to_include, []) and
           acl.id not in ^exclude)
    )
    |> where(
      [stereotyped: stereotyped],
      is_nil(stereotyped.id) or
        stereotyped.stereotype_id not in ^exclude
    )
  end

  def user_default_acl(name), do: user_default_acls()[name]

  # FIXME: this vs acls/0 ?
  def user_default_acls() do
    Map.fetch!(Boundaries.user_default_boundaries(), :acls)
    # |> debug
  end

  def find_caretaker_stereotypes(caretaker, stereotypes) do
    find_caretaker_stereotypes_q(caretaker, stereotypes)
    |> repo().all()

    # |> debug("stereotype acls")
  end

  def find_caretaker_stereotype(caretaker, stereotype) do
    find_caretaker_stereotypes_q(caretaker, stereotype)
    |> repo().one()

    # |> debug("stereotype acls")
  end

  def find_caretaker_stereotypes_q(caretaker, stereotypes) do
    from(a in Acl,
      join: c in Caretaker,
      on: a.id == c.id and c.caretaker_id == ^ulid!(caretaker),
      join: s in Stereotyped,
      on: a.id == s.id and s.stereotype_id in ^ulids(stereotypes),
      preload: [caretaker: c, stereotyped: s]
    )

    # |> debug("stereotype acls")
  end

  def edit(%Acl{} = acl, %User{} = _user, params) do
    acl = repo().maybe_preload(acl, [:named, :extra_info])

    params
    |> input_to_atoms()
    |> Changesets.put_id_on_mixins([:named, :extra_info], acl)
    |> changeset_cast(acl, ...)
    |> repo().update()
  end

  def edit(id, %User{} = user, params) do
    with {:ok, acl} <- get_for_caretaker(id, user) do
      edit(acl, user, params)
    end
  end

  @doc """
  Fully delete the ACL, including permissions/grants and controlled information. This will affect all objects previously shared with this ACL.
  """
  def delete(%Acl{} = acl, opts) do
    assocs = [
      :grants,
      :controlled,
      :caretaker,
      :named,
      :extra_info,
      :stereotyped
    ]

    Bonfire.Social.Objects.maybe_generic_delete(Acl, acl,
      current_user: current_user(opts),
      delete_associations: assocs
    )
  end

  def delete(id, opts) do
    with {:ok, acl} <- get_for_caretaker(id, current_user(opts)) do
      delete(acl, opts)
    end
  end

  @doc """
  Soft-delete the ACL, meaning it will not be displayed anymore, but permissions/grants and controlled information will be preserved. This will not affect objects previously shared with this ACL.
  """
  def soft_delete(%Acl{} = acl, _opts) do
    # FIXME
    Bonfire.Common.Repo.Delete.soft_delete(acl)

    # acl |> repo().delete()
  end

  def soft_delete(id, opts) do
    with {:ok, acl} <- get_for_caretaker(id, current_user(opts)) do
      soft_delete(acl, opts)
    end
  end
end
