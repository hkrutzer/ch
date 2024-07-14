defmodule Ch.Result do
  @moduledoc """
  Result struct returned from any successful query. Its fields are:

    * `command` - An atom of the query command, for example: `:select`, `:insert`
    * `rows` - A list of lists, each inner list corresponding to a row, each element in the inner list corresponds to a column
    * `num_rows` - The number of fetched or affected rows
    * `meta` - The raw metadata from `x-clickhouse-*` response headers
    * `data` - The raw iodata from the response body
  """

  defstruct [:command, :num_rows, :rows, :meta, :data]

  @type t :: %__MODULE__{
          command: Ch.Query.command(),
          num_rows: non_neg_integer | nil,
          rows: [[term]] | nil,
          meta: [{String.t(), term}],
          data: iodata
        }
end
