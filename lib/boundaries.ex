defmodule Bonfire.Boundaries do
  use Bonfire.Common.Utils
  import Bonfire.Boundaries.Integration

  alias Bonfire.Data.Identity.User
  alias Bonfire.Boundaries.Circles
  alias Bonfire.Data.AccessControl.Grant
  alias Bonfire.Data.Identity.Caretaker
  alias Bonfire.Boundaries.Accesses

  @visibility_verbs [:see, :read]

  @doc """
  Assigns the user as the caretaker of the given object or objects,
  replacing the existing caretaker, if any.
  """
  def take_care_of!(things, user) when is_list(things) do
    repo().insert_all(Caretaker, Enum.map(things, &(%{id: Utils.ulid(&1), caretaker_id: Utils.ulid(user)})), on_conflict: :nothing, conflict_target: [:id]) #|> debug
    Enum.map(things, fn thing ->
      case thing do
        %{caretaker: _} ->
          Map.put(thing, :caretaker, %Caretaker{id: thing.id, caretaker_id: Utils.ulid(user), caretaker: user})
        _ -> thing
      end
    end)
  end
  def take_care_of!(thing, user), do: hd(take_care_of!([thing], user))

  def types_blocked(types) when is_list(types) do
    Enum.flat_map(types, &types_blocked/1) |> Enum.uniq()
  end
  def types_blocked(type) when type in [:ghost, :ghost_them] do
    [:ghost_them]
  end
  def types_blocked(type) when type in [:silence, :silence_them] do
    [:silence_them]
  end
  def types_blocked(_) do
    [:silence_them, :ghost_them]
  end

  @doc """
  Block something for everyone on the instance (only doable by admins)
  """
  def instance_wide_block(user_or_instance_to_block, block_type) do
    block(user_or_instance_to_block, block_type, :instance_wide)
  end

  def block(user_or_instance_to_block, block_type, :instance_wide) when block_type in [:silence, :silence_them] do
    instance_wide_circles([:silence_me])
    |> dump("instance_wide_circles_silenced")
    |> add_to_circles(user_or_instance_to_block, ...)
  end

  def block(user_or_instance_to_block, block_type, :instance_wide) do
    instance_wide_circles(types_blocked(block_type))
    |> dump("instance_wide_circles_blocked")
    |> add_to_circles(user_or_instance_to_block, ...)
  end

  @doc """
  Block something for the current user (current_user should be passed in opts)
  """
  def block(user_or_instance_to_block, block_type, opts) when block_type in [:silence, :silence_them] do
    current_user = Utils.current_user(opts)
    silence_them = types_blocked(block_type)
    debug("add silence block to both users' circles, one to my #{inspect silence_them} and the other to their :silence_me")
    with {:ok, ret} <- add_to_blocklist(user_or_instance_to_block, silence_them, current_user), # my list of people I've silenced
    {:ok, ret} <- add_to_blocklist(current_user, [:silence_me], user_or_instance_to_block) do # their list of people who silenced them (this list isn't meant to be visible to them, but is used so queries can filter stuff using `Bonfire.Boundaries.Queries`)
      {:ok, ret}
    end
  end

  def block(user_or_instance_to_block, block_type, opts) do
    add_to_blocklist(user_or_instance_to_block, types_blocked(block_type), Utils.current_user(opts))
  end

  def add_to_blocklist(user_or_instance_add, block_type, circle_caretaker) do
    circle_caretaker
    |> user_circles_blocked(..., block_type)
    |> repo().maybe_preload(caretaker: [caretaker: [:profile]]) |> dump("user:circles_to_block")
    |> add_to_circles(user_or_instance_add, ...)
  end

  defp add_to_circles(user_or_instance_to_block, circles) do
    with done when is_list(done) <- Circles.add_to_circles(user_or_instance_to_block, circles) do # TODO: properly validate the inserts
        {:ok, "Blocked"}
    else e ->
      error(e)
      {:error, "Could not block"}
    end
  end

  def instance_wide_circles(block_types) when is_list(block_types) do
    Enum.map(block_types, &Bonfire.Boundaries.Circles.get_id/1)
  end

  defp user_circles_blocked(current_user, block_types) when is_list(block_types) do
    Circles.get_stereotype_circles(current_user, block_types)
  end

  def is_blocked?(peered, block_type \\ :any, opts \\ [])

  def is_blocked?(user_or_instance, block_type, :instance_wide) do
    instance_wide_circles(types_blocked(block_type))
    |> dump("instance_wide_circles_blocked")
    |> Bonfire.Boundaries.Circles.is_encircled_by?(user_or_instance, ...)
  end

  def is_blocked?(user_or_instance, block_type, opts) do
    debug(opts, "check if blocked #{inspect block_type} instance-wide or per-user, if any has/have been provided in opts")
    is_blocked?(user_or_instance, block_type, :instance_wide)
      ||
    is_blocked_by?(user_or_instance, block_type, opts[:user_ids] || current_user(opts))
  end

  defp is_blocked_by?(%{} = user_or_instance, block_type, current_user_ids) when is_list(current_user_ids) and length(current_user_ids)>0 do
    # dump(user_or_instance, "user_or_instance to check")
    dump(current_user_ids, "current_user_ids")

    block_types = types_blocked(block_type)

    current_user_ids
    |> dump("user_ids")
    |> Enum.map(&user_circles_blocked(&1, block_types))
    # |> dump("user_block_circles")
    |> Bonfire.Boundaries.Circles.is_encircled_by?(user_or_instance, ...)
  end
  defp is_blocked_by?(user_or_instance, block_type, user_id) when is_binary(user_id) do
    is_blocked_by?(user_or_instance, block_type, [user_id])
  end
  defp is_blocked_by?(user_or_instance, block_type, %{} = user) do
    is_blocked_by?(user_or_instance, block_type, [user])
  end
  defp is_blocked_by?(_user, _, _) do
    error("no pattern found for user_or_instance or current_user/current_user_ids")
    nil
  end


  def user_default_boundaries() do
    Config.get!(:user_default_boundaries)
  end

  def preset(preset) when is_binary(preset), do: preset
  def preset(preset_and_custom_boundary), do: maybe_from_opts(preset_and_custom_boundary, :boundary)

  def maybe_custom_circles_or_users(preset_and_custom_boundary), do: maybe_from_opts(preset_and_custom_boundary, :to_circles)

  def maybe_from_opts(preset_and_custom_boundary, key, fallback \\ []) when is_list(preset_and_custom_boundary) do
    preset_and_custom_boundary[key] || fallback
  end
  def maybe_from_opts(_preset_and_custom_boundary, _key, fallback), do: fallback

  def maybe_compose_ad_hoc_acl(base_acl, user) do
  end

end
