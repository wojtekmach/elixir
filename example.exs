defmodule MyURI do
  defstruct [:uri]

  defmacro __call__({:<<>>, _, _} = binary) do
    uri = URI.parse(binary)
    Macro.escape(%MyURI{uri: uri})
  end

  defmacro __call__(other) do
    quote do
      %MyURI{uri: URI.parse(unquote(other))}
    end
  end

  defimpl Inspect do
    def inspect(uri, _) do
      "URI(\"" <> URI.to_string(uri.uri) <> "\")"
    end
  end

  defimpl String.Chars do
    def to_string(uri) do
      URI.to_string(uri.uri)
    end
  end
end

defmodule MyMapSet do
  defmacro __call__(list) do
    if __CALLER__.context == :match do
      map = Map.from_keys(list, [])

      quote do
        %MapSet{map: unquote(Macro.escape(map))}
      end
    else
      quote do
        MapSet.new(unquote(list))
      end
    end
  end
end

defmodule MyString do
  def __call__(term) do
    String.Chars.to_string(term)
  end
end

defmodule Main do
  alias MyURI, as: URI
  alias MyMapSet, as: MapSet
  alias MyString, as: String

  require URI
  require MapSet

  def main do
    IO.inspect(URI("https://elixir-lang.org"))

    uri = "https://elixir-lang.org"
    IO.inspect(String(URI(uri)))

    IO.inspect(match?(MapSet([1]), MapSet([1, 2])))
    IO.inspect(match?(MapSet([3]), MapSet([1, 2])))
  end
end

Main.main()
