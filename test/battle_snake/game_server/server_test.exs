defmodule BattleSnake.GameServer.ServerTest do
  alias BattleSnake.GameServer.Server
  alias BattleSnake.GameState
  use BattleSnake.Case, async: false

  def create_game_form(_) do
    [game_form: create(:game_form)]
  end

  ########
  # Init #
  ########

  describe "Server.init(GameState.t)" do
    test "returns ok" do
      assert {:ok, %GameState{}} == Server.init(%GameState{})
    end
  end

  describe "Server.init(integer)" do
    setup [:create_game_form]

    test "initializes the game state with the id", c do
      assert {:ok, state} = Server.init(c.game_form.id)
      assert state.game_form_id == c.game_form.id
      assert state.game_form.id == c.game_form.id
    end

    test "stops when the game form does not exist" do
      assert {:stop, %Mnesia.RecordNotFoundError{}} = Server.init("fake")
    end
  end

  describe "Server.init(GameForm.t)" do
    setup do
      snake = build(:snake_form, url: "url")
      game_form = build(:game_form, id: 1, snakes: [snake])
      [game_form: game_form]
    end

    test "initializes the game state with the id", c do
      assert {:ok, state} = Server.init(c.game_form)
      assert state.game_form_id == c.game_form.id
      assert state.game_form.id == c.game_form.id
    end

    test "sets .world", c do
      assert {:ok, state} = Server.init(c.game_form)
      assert state.world.__struct__ == BattleSnake.World
    end

    test "sets .world.snakes", c do
      assert {:ok, state} = Server.init(c.game_form)
      assert assert [%BattleSnake.Snake{}] = state.world.snakes
    end

    test "sets .snakes", c do
      assert {:ok, state} = Server.init(c.game_form)
      assert is_map state.snakes
      assert [id] = Map.keys(state.snakes)
      assert [
        %BattleSnake.Snake{
          id: ^id,
          coords: [_, _, _]}
      ] = Map.values(state.snakes)
    end
  end

  ##################
  # Get Game State #
  ##################

  describe "Server.handle_call(:get_game_state, _, _)" do
    test "returns the state" do
      assert Server.handle_call(:get_game_state, self(), 1) == {:reply, 1, 1}
    end
  end

  ########
  # Tick #
  ########

  describe "Server.handle_info(:tick, state) when status is not :cont" do
    test "does nothing" do
      state = build(:state, status: :hatled)
      assert {:noreply, ^state} = Server.handle_info(:tick, state)
    end
  end

  describe "Server.handle_info(:tick, state) when state.status is cont and game is done" do
    test "halts the game" do
      objective = fn _ -> true end
      state = build(:state, status: :cont, objective: objective)
      assert {:noreply, state} = Server.handle_info(:tick, state)
      assert state.status == :halted
    end
  end

  describe "Server.handle_info(:tick, state) when state.status is cont" do
    test "sends a :tick message after the confiured delay as a lower bound" do
      objective = fn _ -> false end
      state = build(:state, status: :cont, delay: 2, objective: objective)

      Server.handle_info(:tick, state)
      assert_receive :tick, 10
    end

    test "sends a :tick message after execution as an upper bound" do
      objective = fn _ ->
        Process.sleep(2)
        false
      end

      state = build(:state, status: :cont, delay: 0, objective: objective)

      Server.handle_info(:tick, state)
      assert_receive :tick, 10
    end
  end

  #############
  # Game Done #
  #############

  describe "Server.handle_info(:game_done, state)" do
    test "deletes any previous records for this game" do
      import BattleSnake.GameResultSnake

      snake = build(:snake, id: "snake-1")

      snakes = %{"snake-1" => snake}

      state = build(:state,
        game_form_id: "game-1",
        winners: ["snake-1"],
        snakes: snakes)

      :ok = game_result_snake(id: "0", game_id: "game-0", snake_id: "snake-0")
      |> Mnesia.dirty_write

      :ok = game_result_snake(id: "1", game_id: "game-1", snake_id: "snake-1")
      |> Mnesia.dirty_write

      Server.handle_info(:game_done, state)

      actual = BattleSnake.GameResultSnake
      |> Mnesia.dirty_all
      |> Enum.sort_by(&elem(&1, game_result_snake(:game_id)))

      assert [
        game_result_snake(id: "0", game_id: "game-0", snake_id: "snake-0"),
        game_result_snake(game_id: "game-1", snake_id: "snake-1"),
      ] = actual
    end

    test "writes the winner to disk" do
      import BattleSnake.GameResultSnake

      snake = build(:snake, id: "snake-1")

      snakes = %{"snake-1" => snake}

      state = build(:state,
        game_form_id: "game-1",
        winners: ["snake-1"],
        snakes: snakes)

      Server.handle_info(:game_done, state)

      assert [game_result_snake(snake_id: "snake-1")] =
        Mnesia.dirty_all(BattleSnake.GameResultSnake)
    end
  end

  ########
  # Next #
  ########

  describe "Server.handle_call(:next, pid, state)" do
    test "suspends the game" do
      state = build(:state, status: :cont)
      assert {:reply, :ok, state} = Server.handle_call(:next, self(), state)
      assert state.status == :suspend
    end

    test "does nothing when the game is halted" do
      state = build(:state, status: :halted)
      assert {:reply, :ok, ^state} = Server.handle_call(:next, self(), state)
    end
  end

  #########
  # Pause #
  #########

  describe "Server.handle_call(:pause, pid, state)" do
    test "suspends the game" do
      state = build(:state, status: :cont)
      assert {:reply, :ok, state} = Server.handle_call(:pause, self(), state)
      assert state.status == :suspend
    end

    test "does nothing when the game is suspended" do
      state = build(:state, status: :suspend)
      assert {:reply, :ok, ^state} = Server.handle_call(:pause, self(), state)
    end
  end

  ########
  # Prev #
  ########

  describe "Server.handle_call(:prev, pid, state)" do
    test "suspends the game" do
      state = build(:state, status: :halted)
      assert {:reply, :ok, state} = Server.handle_call(:prev, self(), state)
      assert state.status == :suspend
    end
  end

  ##########
  # Resume #
  ##########

  describe "Server.handle_call(:resume, pid, state)" do
    test "continues the game" do
      state = build(:state, status: :suspend)
      assert {:reply, :ok, state} = Server.handle_call(:resume, self(), state)
      assert state.status == :cont
    end

    test "sends a tick message" do
      state = build(:state, status: :suspend)
      assert {:reply, :ok, _state} = Server.handle_call(:resume, self(), state)
      assert_receive :tick, 10
    end
  end

  ##########
  # Replay #
  ##########
end
