defmodule Otto.Tool do
  @moduledoc """
  Behaviour for defining tools that can be invoked by Otto agents.

  Tools are discrete functions that agents can use to interact with external systems,
  execute operations, or retrieve information. Each tool must specify its capabilities
  and permissions to enable proper sandboxing and security controls.

  ## Callbacks

  - `name/0` - Returns a unique string identifier for the tool
  - `permissions/0` - Returns a list of permission atoms (`:read`, `:write`, `:exec`)
  - `call/2` - Executes the tool with given parameters and context

  ## Example

      defmodule MyTools.FileReader do
        @behaviour Otto.Tool

        def name, do: "file_reader"
        def permissions, do: [:read]

        def call(%{path: path}, %Otto.ToolContext{working_dir: working_dir}) do
          full_path = Path.join(working_dir, path)
          File.read(full_path)
        end
      end
  """

  @doc """
  Returns a unique string identifier for this tool.
  Must be unique within the tool registry.
  """
  @callback name() :: String.t()

  @doc """
  Returns a list of permissions required by this tool.
  Valid permissions: `:read`, `:write`, `:exec`
  """
  @callback permissions() :: [atom()]

  @doc """
  Executes the tool with given parameters and context.
  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @callback call(params :: map(), context :: Otto.ToolContext.t()) ::
              {:ok, term()} | {:error, term()}
end