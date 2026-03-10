defmodule JidoStorageEcto.DataCase do
  @moduledoc """
  Test case template that sets up the Ecto SQL Sandbox.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias JidoStorageEcto.TestRepo
    end
  end

  setup tags do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(JidoStorageEcto.TestRepo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
