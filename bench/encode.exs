defmodule Bench do
  def now(input) do
    [Enum.map([:col1, :col2, :col3, :col4], fn field -> Map.fetch!(input, field) end)]
    |> Ch.RowBinary._encode_rows([:u64, :datetime, {:array, :u8}, :string])
  end

  def next(%{col1: col1, col2: col2, col3: col3, col4: col4}) do
    [
      <<
        col1::64-unsigned-integer,
        to_unix(col2)::64-unsigned-integer
      >>,
      length(col3),
      col3,
      byte_size(col4),
      col4
    ]
  end

  %Date{year: year, month: month} = Date.utc_today()
  new_epoch = DateTime.to_unix(DateTime.new!(Date.new!(year, month, 1), Time.new!(0, 0, 0)))

  defp to_unix(%DateTime{
         year: unquote(year),
         month: unquote(month),
         day: day,
         hour: hour,
         minute: minute,
         second: second
       }) do
    unquote(new_epoch) + (day - 1) * 86400 + hour * 3600 + minute * 60 + second
  end

  # defp to_unix2(%DateTime{
  #   year: unquote(year),
  #   month: unquote(month),
  #   day: day,
  #   hour: hour,
  #   minute: minute,
  #   second: second
  # }) do

  # end
end

# CREATE TABLE benchmark (
#   col1 UInt64,
#   col2 String,
#   col3 Array(UInt8),
#   col4 DateTime
# ) Engine Null

Benchee.run(
  %{
    "now" => &Bench.now/1,
    "next" => &Bench.next/1
  },
  profile_after: true,
  memory_time: 2,
  inputs: %{
    "small" => %{
      col1: 1000,
      col2: DateTime.utc_now(),
      col3: [1, 2, 3],
      col4: "hellow"
    }
  }
)
