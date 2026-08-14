defmodule LetflowQueue.Tasks.JSONList do
  @moduledoc """
  Ecto type storing a list of strings as a JSON-encoded text column.

  Used for `acceptance_criteria`, where every element must be a string.
  """

  use Ecto.Type

  def type, do: :string

  def cast(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, list}
    else
      :error
    end
  end

  def cast(_), do: :error

  def load(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  def load(_), do: :error

  def dump(list) when is_list(list) do
    Jason.encode(list)
  end

  def dump(_), do: :error
end
