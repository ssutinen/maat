defmodule Maat.Schemas do
  @moduledoc "Loads the JSON Schema contract files from `schemas/`."

  def dir do
    cwd = Path.expand("schemas")
    if File.dir?(cwd), do: cwd, else: Application.app_dir(:maat, "schemas")
  end

  def load(name), do: dir() |> Path.join(name) |> File.read!() |> Jason.decode!()
end
