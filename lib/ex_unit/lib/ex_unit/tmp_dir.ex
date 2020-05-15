defmodule ExUnit.TmpDir do
  @doc """
  Returns a path to a temporary directory for the current test.

  The directory is lazily created on the first access and is automatically
  removed once the test finishes (regardless if the test suceeds or fails).
  """
  defmacro tmp_dir do
    test = Module.get_attribute(__CALLER__.module, :ex_unit_test)

    unless test do
      raise "cannot invoke tmp_dir/0 outside of a test. Please make sure you have invoked " <>
              "\"use ExUnit.Case\" in the current module"
    end

    path = Path.join([System.tmp_dir(), "#{inspect(test.module)}_#{test.name}"])
    tmp_dirs = Module.get_attribute(__CALLER__.module, :ex_unit_tmp_dirs)

    if test.name in tmp_dirs do
      quote do
        unquote(path)
      end
    else
      Module.put_attribute(__CALLER__.module, :ex_unit_tmp_dirs, [test.name | tmp_dirs])

      quote bind_quoted: [path: path] do
        File.mkdir_p!(path)
        on_exit(fn -> File.rm_rf!(path) end)
        path
      end
    end
  end
end
