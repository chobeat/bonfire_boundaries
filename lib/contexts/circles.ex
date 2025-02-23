defmodule Bonfire.Boundaries.Circles do
  use Bonfire.Common.Utils
  import Bonfire.Boundaries.Integration
  import Bonfire.Boundaries.Queries
  import Ecto.Query
  import EctoSparkles

  alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries.Circles
  # alias Bonfire.Data.AccessControl.Stereotyped
  alias Bonfire.Data.Identity.ExtraInfo
  alias Bonfire.Data.Identity.Named
  alias Bonfire.Data.AccessControl.Circle
  alias Bonfire.Data.AccessControl.Encircle

  alias Bonfire.Data.Identity.Caretaker
  # alias Ecto.Changeset
  alias Needle.Changesets
  # alias Needle.Pointer

  # don't show "others who silenced me" in circles
  @reverse_stereotypes ["0KF1NEY0VD0N0TWANTT0HEARME"]
  @default_q_opts [exclude_circles: @reverse_stereotypes]
  @block_stereotypes ["7N010NGERWANTT011STENT0Y0V", "7N010NGERC0NSENTT0Y0VN0WTY"]
  # @exclude_stereotypes ["7N010NGERWANTT011STENT0Y0V", "7N010NGERC0NSENTT0Y0VN0WTY", "4THEPE0P1ES1CH00SET0F0110W", "7DAPE0P1E1PERM1TT0F0110WME"]
  @follow_stereotypes [
    "7DAPE0P1E1PERM1TT0F0110WME",
    "4THEPE0P1ES1CH00SET0F0110W"
  ]

  # special built-in circles (eg, guest, local, activity_pub)
  def circles, do: Config.get([:circles], %{})

  def stereotype_ids do
    circles()
    |> Map.values()
    |> Enum.filter(&e(&1, :stereotype, nil))
    |> Enum.map(& &1.id)
  end

  def stereotypes(:follow), do: @follow_stereotypes
  def stereotypes(:block), do: @block_stereotypes ++ @reverse_stereotypes

  def built_in_ids do
    circles()
    |> Map.values()
    |> Enums.ids()
  end

  def is_built_in?(circle) do
    # debug(acl)
    ulid(circle) in built_in_ids()
  end

  def is_stereotype?(acl) do
    ulid(acl) in stereotype_ids()
  end

  def get(slug) when is_atom(slug), do: circles()[slug]
  def get(id) when is_binary(id), do: get_tuple(id) |> Enums.maybe_elem(1)

  def get!(slug) when is_atom(slug) do
    get(slug) ||
      raise RuntimeError, message: "Missing built-in circle: #{inspect(slug)}"
  end

  def get_id(slug), do: Map.get(circles(), slug, %{})[:id]

  def get_id!(slug) when is_atom(slug), do: get!(slug).id

  def get_tuple(slug) when is_atom(slug) do
    {Config.get!([:circles, slug, :name]), Config.get!([:circles, slug, :id])}
  end

  def get_tuple(id) when is_binary(id) do
    Enum.find(circles(), fn {_slug, c} ->
      c[:id] == id
    end)
  end

  def list_my_defaults(_user \\ nil) do
    # TODO make configurable
    Enum.map([:guest, :local, :activity_pub], &Circles.get_tuple/1)
  end

  def list_built_ins() do
    Enum.map(circles(), fn {_slug, %{id: id}} ->
      id
    end)
    |> list_by_ids()
  end

  # def list, do: repo().many(from(u in Circle, left_join: named in assoc(u, :named), preload: [:named]))
  def list_by_ids(ids),
    do:
      repo().many(
        from(c in Circle,
          left_join: named in assoc(c, :named),
          where: c.id in ^ulid(ids),
          preload: [:named]
        )
      )

  def circle_ids(subjects) when is_list(subjects),
    do: subjects |> Enum.map(&circle_ids/1) |> Enum.uniq()

  def circle_ids(circle_name)
      when is_atom(circle_name) and not is_nil(circle_name),
      do: get_id(circle_name)

  def circle_ids(%{id: subject_id}), do: subject_id
  def circle_ids(subject_id) when is_binary(subject_id), do: subject_id
  def circle_ids(_), do: nil

  def to_circle_ids(subjects) do
    public = get_id(:guest)
    selected_circles = circle_ids(subjects)
    # public/guests defaults to also being visible to local users and federating
    if public in selected_circles or :guest in selected_circles do
      selected_circles ++
        [
          get_id!(:local),
          get_id!(:activity_pub)
        ]
    else
      selected_circles
    end
    |> Enum.uniq()
  end

  # def create(%{}=attrs) do
  #   repo().insert(changeset(:create, attrs))
  # end

  @doc "Create a circle for the provided user (and with the user in the circle?)"
  def create(user, %{} = attrs) when is_map(user) or is_binary(user) do
    with {:ok, circle} <-
           repo().insert(
             changeset(
               :create,
               attrs
               |> input_to_atoms()
               |> deep_merge(%{
                 caretaker: %{caretaker_id: ulid!(user)}
                 # encircles: [%{subject_id: user.id}] # add myself to circle?
               })
             )
           ) do
      # Bonfire.Boundaries.Boundaries.maybe_make_visible_for(user, circle) # make visible to myself - FIXME
      {:ok, circle}
    end
  end

  def create(:instance, %{} = attrs) do
    create(
      Bonfire.Boundaries.Fixtures.admin_circle(),
      attrs
    )
  end

  def create(user, name) when is_binary(name) do
    create(user, %{named: %{name: name}})
  end

  def changeset(circle \\ %Circle{}, attrs)

  def changeset(:create, attrs),
    do:
      changeset(attrs)
      |> Changesets.cast_assoc(:caretaker, with: &Caretaker.changeset/2)

  def changeset(%Circle{} = circle, attrs) do
    Circle.changeset(circle, attrs)
    |> Changesets.cast(attrs, [])
    |> Changesets.cast_assoc(:named, with: &Named.changeset/2)
    |> Changesets.cast_assoc(:extra_info, with: &ExtraInfo.changeset/2)
    |> Changesets.cast_assoc(:encircles, with: &Encircle.changeset/2)
  end

  def changeset(:update, circle, params) do
    # Ecto doesn't like mixed keys so we convert them all to strings
    params = for {k, v} <- params, do: {to_string(k), v}, into: %{}
    # debug(params)

    changeset(circle, params)
  end

  @doc """
  Lists the circles that we are permitted to see.
  """
  def is_encircled_by?(subject, circle)
      when is_nil(subject) or is_nil(circle) or subject == [] or circle == [],
      do: nil

  def is_encircled_by?(subject, circle) when is_atom(circle) and not is_nil(circle),
    do: is_encircled_by?(subject, get_id!(circle))

  def is_encircled_by?(subject, circles)
      when is_list(circles) or is_binary(circles) or is_map(circles),
      do: repo().exists?(is_encircled_by_q(subject, circles))

  # @doc "query for `list_visible`"
  def is_encircled_by_q(subject, circles) do
    encircled_by_q(subject)
    |> where(
      [encircle: encircle],
      encircle.circle_id in ^ulids(circles)
    )
  end

  defp encircled_by_q(subject) do
    from(encircle in Encircle, as: :encircle)
    |> where(
      [encircle: encircle],
      encircle.subject_id in ^ulids(subject)
    )
  end

  def preload_encircled_by(subject, circles, opts \\ []) do
    circles
    |> repo().preload([encircles: encircled_by_q(subject)], opts)
    |> debug()
  end

  ## invariants:
  ## * Created circles will have the user as a caretaker

  def get_for_caretaker(id, caretaker, opts \\ []) do
    with {:ok, circle} <-
           repo().single(query_my_by_id(id, caretaker, opts ++ @default_q_opts)) do
      {:ok, circle}
    else
      {:error, :not_found} ->
        if Bonfire.Boundaries.can?(current_account(opts) || caretaker, :assign, :instance) ||
             opts[:scope] == :instance_wide,
           do:
             repo().single(
               query_my_by_id(
                 id,
                 Bonfire.Boundaries.Fixtures.admin_circle(),
                 opts ++ @default_q_opts
               )
             ),
           else: {:error, :not_found}
    end
  end

  def get_by_name(name, caretaker) do
    repo().single(query_basic_my(caretaker, name: name))
  end

  def get_stereotype_circles(subject, stereotypes)
      when is_list(stereotypes) and stereotypes != [] do
    stereotypes = Enum.map(stereotypes, &Bonfire.Boundaries.Circles.get_id!/1)

    # skip boundaries since we should only use this query internally
    query_my(subject, skip_boundary_check: true)
    |> where(
      [circle: circle, stereotyped: stereotyped],
      stereotyped.stereotype_id in ^ulids(stereotypes)
    )
    |> repo().all()
  end

  def get_stereotype_circles(subject, stereotype)
      when not is_nil(stereotype) and stereotype != [],
      do: get_stereotype_circles(subject, [stereotype])

  @doc """
  Lists the circles that we are permitted to see.
  """
  def list_visible(user, opts \\ []),
    do: repo().many(query_visible(user, opts ++ @default_q_opts))

  @doc """
  Lists the circles we are the registered caretakers of that we are
  permitted to see. If any circles are created without permitting the
  user to see them, they will not be shown.
  """
  def list_my(user, opts \\ []),
    do: repo().many(query_my(user, opts ++ @default_q_opts))

  def list_my_with_global(user, opts \\ []) do
    list_my(
      user,
      opts ++
        [
          extra_ids_to_include:
            opts[:global_circles] || Bonfire.Boundaries.Fixtures.global_circles()
        ]
    )
  end

  def list_my_with_counts(user, opts \\ []) do
    query_my(user, opts ++ @default_q_opts)
    |> join(
      :left,
      [circle],
      encircles in subquery(
        from(ec in Encircle,
          group_by: ec.circle_id,
          select: %{circle_id: ec.circle_id, count: count()}
        )
      ),
      on: encircles.circle_id == circle.id,
      as: :encircles
    )
    |> select_merge([encircles: encircles], %{encircles_count: encircles.count})
    # |> order_by([encircles: encircles], desc_nulls_last: encircles.count) # custom order messes with pagination
    |> many(opts[:paginate?], opts)
  end

  @doc "query for `list_visible`"
  def query(opts \\ []) do
    exclude_circles =
      e(opts, :exclude_circles, []) ++
        if opts[:exclude_built_ins],
          do: built_in_ids(),
          else:
            if(opts[:exclude_stereotypes],
              do: stereotype_ids(),
              else:
                if(opts[:exclude_block_stereotypes],
                  do: @block_stereotypes,
                  else: []
                )
            )

    from(circle in Circle, as: :circle)
    |> proload([
      :named,
      :extra_info,
      :caretaker,
      stereotyped: {"stereotype_", [:named]}
    ])
    |> where(
      [circle, stereotyped: stereotyped],
      circle.id not in ^exclude_circles and
        (is_nil(stereotyped.id) or
           stereotyped.stereotype_id not in ^exclude_circles)
    )
    |> maybe_by_name(opts[:name])
    |> maybe_search(opts[:search])
  end

  defp maybe_by_name(query, text) when is_binary(text) and text != "" do
    query
    |> where(
      [named: named],
      named.name == ^text
    )
  end

  defp maybe_by_name(query, _), do: query

  defp maybe_search(query, text) when is_binary(text) and text != "" do
    query
    |> where(
      [named: named, stereotype_named: stereotype_named],
      ilike(named.name, ^"#{text}%") or
        ilike(named.name, ^"% #{text}%") or
        ilike(stereotype_named.name, ^"#{text}%") or
        ilike(stereotype_named.name, ^"% #{text}%")
    )
  end

  defp maybe_search(query, _), do: query

  @doc "query for `list_visible`"
  def query_visible(user, opts \\ []) do
    opts = to_options(opts)

    query(opts)
    |> boundarise(circle.id, opts ++ [current_user: user])
  end

  defp query_basic(opts) do
    from(circle in Circle, as: :circle)
    |> proload([
      :named,
      :caretaker
    ])
    |> maybe_by_name(opts[:name])
    |> maybe_search(opts[:search])
  end

  defp query_basic_my(user, opts \\ []) when not is_nil(user) do
    query_basic(opts)
    |> where(
      [circle, caretaker: caretaker],
      caretaker.caretaker_id == ^ulid!(user) or
        circle.id in ^e(opts, :extra_ids_to_include, [])
    )
  end

  @doc "query for `list_my`"
  def query_my(caretaker, opts \\ [])

  def query_my(caretaker, opts)
      when (is_binary(caretaker) or is_map(caretaker) or is_list(caretaker)) and caretaker != [] do
    opts = to_options(opts)

    query(opts)
    |> where(
      [circle, caretaker: caretaker],
      caretaker.caretaker_id in ^ulids(caretaker) or
        circle.id in ^e(opts, :extra_ids_to_include, [])
    )
  end

  def query_my(:instance, opts), do: Bonfire.Boundaries.Fixtures.admin_circle() |> query_my(opts)

  @doc "query for `get`"
  def query_my_by_id(id, caretaker, opts \\ []) do
    query_my(caretaker, opts)
    # |> reusable_join(:inner, [circle: circle], caretaker in assoc(circle, :caretaker), as: :caretaker)
    |> where(
      [circle: circle],
      circle.id == ^ulid!(id)
    )
  end

  def get_or_create(name, caretaker \\ nil) when is_binary(name) do
    # instance-wide circle if not user provided
    caretaker = caretaker || Bonfire.Boundaries.Fixtures.admin_circle()

    case get_by_name(name, caretaker) do
      {:ok, circle} ->
        {:ok, circle}

      _none ->
        debug(name, "circle unknown, create it now")
        create(caretaker, name)
    end
  end

  def edit(%Circle{} = circle, %User{} = _user, params) do
    circle = repo().maybe_preload(circle, [:encircles, :named, :extra_info])

    params
    |> input_to_atoms()
    |> Changesets.put_id_on_mixins([:named, :extra_info], circle)
    # |> input_to_atoms()
    # |> Map.update(:named, nil, &Map.put(&1, :id, ulid(circle)))
    # |> Map.update(:extra_info, nil, &Map.put(&1, :id, ulid(circle)))
    |> changeset(:update, circle, ...)
    |> repo().update()
  end

  def edit(id, %User{} = user, params) do
    with {:ok, circle} <- get_for_caretaker(id, user) do
      edit(circle, user, params)
    end
  end

  def add_to_circles(_subject, circles)
      when is_nil(circles) or (is_list(circles) and length(circles) == 0),
      do: error("No circle ID provided, so could not add")

  def add_to_circles(subjects, _circles)
      when is_nil(subjects) or (is_list(subjects) and length(subjects) == 0),
      do: error("No subject ID provided, so could not add")

  def add_to_circles(subjects, circle) when is_list(subjects) do
    # TODO: optimise
    Enum.map(subjects, &add_to_circles(&1, circle))
  end

  def add_to_circles(subject, circles) when is_list(circles) do
    # TODO: optimise
    Enum.map(circles, &add_to_circles(subject, &1))
  end

  def add_to_circles(subject, circle) when not is_nil(circle) do
    repo().insert(Encircle.changeset(%{circle_id: ulid!(circle), subject_id: ulid!(subject)}))
  end

  def remove_from_circles(_subject, circles)
      when is_nil(circles) or (is_list(circles) and length(circles) == 0),
      do: error("No circle ID provided, so could not remove")

  def remove_from_circles(subject, circles) when is_list(circles) do
    from(e in Encircle,
      where: e.subject_id == ^ulid(subject) and e.circle_id in ^ulid(circles)
    )
    |> repo().delete_all()
  end

  def remove_from_circles(subject, circle) do
    remove_from_circles(subject, [circle])
  end

  def empty_circles(circles) when is_list(circles) do
    from(e in Encircle,
      where: e.circle_id in ^ulid(circles)
    )
    |> repo().delete_all()
  end

  @doc """
  Fully delete the circle, including membership and boundary information. This will affect all objects previously shared with members of this circle.
  """
  def delete(%Circle{} = circle, opts) do
    Bonfire.Common.Utils.maybe_apply(
      Bonfire.Social.Objects,
      :maybe_generic_delete,
      [
        Circle,
        circle,
        [
          current_user: current_user(opts),
          delete_associations: [:encircles, :caretaker, :named, :extra_info, :stereotyped]
        ]
      ]
    )
  end

  def delete(id, opts) do
    with {:ok, circle} <- get_for_caretaker(id, current_user(opts)) do
      delete(circle, opts)
    end
  end
end
