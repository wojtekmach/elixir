code = """
defmodule Foo do
  def foo(a, b) do
    a + b
  end
end
"""

transform = &Macro.prewalk(&1, fn
  {:defmodule, meta1, [{:__aliases__, meta2, [:Foo]}, do_block]} ->
    {:defmodule, meta1, [{:__aliases__, meta2, [:Bar]}, do_block]}

  {:def, meta1, [{:foo, meta2, args}, expr]} ->
    {:def, meta1, [{:bar, meta2, args}, expr]}

  other ->
    other
end)

IO.puts "before:"
IO.puts code

IO.puts "after:"

code
|> Code.format_string!(transform: transform)
|> IO.puts()
