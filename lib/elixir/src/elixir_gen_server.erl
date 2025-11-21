-module(elixir_gen_server).

-export([init_it/6]).

init_it(Starter, Parent, Name, Mod, {Args, Callers}, Options) ->
    case Callers of
      nil -> ok;
      _ -> erlang:put('$callers', Callers)
    end,
    gen_server:init_it(Starter, Parent, Name, Mod, Args, Options).
