defmodule Bonfire.Boundaries.LiveHandler do
  use Bonfire.Web, :live_handler
  import Bonfire.Boundaries.Integration

  def handle_event("block", %{"id" => id, "scope" => scope} = attrs, socket) when is_binary(id) do
    with {:ok, status} <- (
      if is_admin?(current_user(socket)) do
      Bonfire.Boundaries.Blocks.block(id, maybe_to_atom(attrs["block_type"]), maybe_to_atom(scope) || socket)
    else
      debug("not admin, fallback to user-level block")
      Bonfire.Boundaries.Blocks.block(id, maybe_to_atom(attrs["block_type"]), socket)
    end
    ) do
      Bonfire.UI.Social.OpenModalLive.close()
      {:noreply,
          socket
          |> put_flash(:info, status)
      }
    end
  end

  def handle_event("block", %{"id" => id} = attrs, socket) when is_binary(id) do
    with {:ok, status} <- Bonfire.Boundaries.Blocks.block(id, maybe_to_atom(attrs["block_type"]), socket) do
      Bonfire.UI.Social.OpenModalLive.close()
      {:noreply,
          socket
          |> put_flash(:info, status)
      }
    end
  end

    def handle_event("unblock", %{"id" => id, "scope" => scope} = attrs, socket) when is_binary(id) do
    with {:ok, status} <- (
      if is_admin?(current_user(socket)) do
      Bonfire.Boundaries.Blocks.unblock(id, maybe_to_atom(attrs["block_type"]), maybe_to_atom(scope) || socket)
    else
      debug("not admin, fallback to user-level block")
      Bonfire.Boundaries.Blocks.unblock(id, maybe_to_atom(attrs["block_type"]), socket)
    end
    ) do
      {:noreply,
          socket
          |> put_flash(:info, status)
      }
    end
  end

  def handle_event("unblock", %{"id" => id} = attrs, socket) when is_binary(id) do
    with {:ok, status} <- Bonfire.Boundaries.Blocks.unblock(id, maybe_to_atom(attrs["block_type"]), socket) do
      {:noreply,
          socket
          |> put_flash(:info, status)
      }
    end
  end

  # def handle_event("input", %{"circles" => selected_circles} = _attrs, socket) when is_list(selected_circles) and length(selected_circles)>0 do

  #   previous_circles = e(socket, :assigns, :to_circles, []) #|> Enum.uniq()

  #   new_circles = set_circles(selected_circles, previous_circles)

  #   {:noreply,
  #       socket
  #       |> assign_global(
  #         to_circles: new_circles
  #       )
  #   }
  # end

  # def handle_event("input", _attrs, socket) do # no circle
  #   {:noreply,
  #     socket
  #       |> assign_global(
  #         to_circles: []
  #       )
  #   }
  # end

  def handle_event("select", %{"id" => selected} = _attrs, socket) when is_binary(selected) do

    previous_circles = e(socket, :assigns, :to_circles, []) #|> IO.inspect

    new_circles = set_circles([selected], previous_circles, true) #|> IO.inspect

    {:noreply,
        socket
        |> assign_global(
          to_circles: new_circles
        )
    }
  end

  def handle_event("deselect", %{"id" => deselected} = _attrs, socket) when is_binary(deselected) do

    new_circles = remove_from_circle_tuples([deselected], e(socket, :assigns, :to_circles, [])) #|> IO.inspect

    {:noreply,
        socket
        |> assign_global(
          to_circles: new_circles
        )
    }
  end

  def set_circles(selected_circles, previous_circles, add_to_previous \\ false) do

    # debug(previous_circles: previous_circles)
    # selected_circles = Enum.uniq(selected_circles)

    # debug(selected_circles: selected_circles)

    previous_ids = previous_circles |> Enum.map(fn
        {_name, id} -> id
        _ -> nil
      end)
    # debug(previous_ids: previous_ids)

    public = Bonfire.Boundaries.Circles.circles()[:guest]

    selected_circles = if public in selected_circles and public not in previous_ids do # public/guests defaults to also being visible to local users and federating
      selected_circles ++ [
        Bonfire.Boundaries.Circles.circles()[:local],
        Bonfire.Boundaries.Circles.circles()[:admin],
        Bonfire.Boundaries.Circles.circles()[:activity_pub]
      ]
    else
      selected_circles
    end

    # debug(new_selected_circles: selected_circles)

    existing = if add_to_previous, do: previous_circles, else: known_circle_tuples(selected_circles, previous_circles)


    # fix this ugly thing
    (
     existing
     ++
     Enum.map(selected_circles, &Bonfire.Boundaries.Circles.get_tuple/1)
    )
    |> Utils.filter_empty([]) |> Enum.uniq()
    # |> debug()
  end

  def known_circle_tuples(selected_circles, previous_circles) do
    previous_circles
    |> Enum.filter(fn
        {_name, id} -> id in selected_circles
        _ -> nil
      end)
  end

  def remove_from_circle_tuples(deselected_circles, previous_circles) do
    previous_circles
    |> Enum.filter(fn
        {_name, id} -> id not in deselected_circles
        _ -> nil
      end)
  end

    alias Bonfire.Boundaries.Circles


  def handle_event("create_circle", %{"name" => name}, socket) do
  # params = input_to_atoms(params)

    with {:ok, %{id: id} = _circle} <-
      Circles.create(current_user(socket), name) do

          {:noreply,
          socket
          |> put_flash(:info, "Circle create!")
          |> push_redirect(to: "/settings/circle/"<>id)
          }

    end
  end

  def handle_event("member_update", %{"circle" => %{"id" => id} = params}, socket) do
    # params = input_to_atoms(params)

      with {:ok, _circle} <-
        Circles.update(id, current_user(socket), %{encircles: e(params, "encircle", [])}) do

            {:noreply,
            socket
            |> put_flash(:info, "OK")
            }

      end
    end
end
