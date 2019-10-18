defmodule UserDefault do
  defmacro time(expr) do
    quote do
      time1 = :erlang.monotonic_time()
      result = unquote(expr)
      time2 = :erlang.monotonic_time()
      time = :erlang.convert_time_unit(time2 - time1, :native, :microsecond)

      formatted_time =
        if time > 1000 do
          [time |> div(1000) |> Integer.to_string(), "ms"]
        else
          [Integer.to_string(time), "µs"]
        end

      IO.puts([IO.ANSI.yellow(), "time: ", formatted_time, IO.ANSI.reset()])
      result
    end
  end
end
