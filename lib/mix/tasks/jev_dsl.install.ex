if Code.ensure_loaded?(Igniter.Mix.Task) do
  defmodule Mix.Tasks.JevDsl.Install do
    @shortdoc "Installs JevDSL into a project. Invoke with `mix igniter.install jev_dsl`."
    @moduledoc """
    #{@shortdoc}

    Configures `.formatter.exs` with `import_deps: [:jev_dsl]` and optionally generates
    a starter `JevDSL` contract module when `--module` is passed.

    ## Example

        mix igniter.install jev_dsl --yes
        mix igniter.install jev_dsl --module MyApp.TriageContracts --yes
    """

    use Igniter.Mix.Task

    alias Igniter.Project.{Application, Formatter}
    alias Igniter.Project.Module, as: ProjectModule

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :jev_dsl,
        example: "mix igniter.install jev_dsl --module MyApp.TriageContracts",
        positional: [],
        schema: [module: :string, yes: :boolean],
        aliases: [m: :module, y: :yes],
        defaults: [],
        composes: [],
        adds_deps: [],
        installs: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> Formatter.import_dep(:jev_dsl)
      |> maybe_create_contract_module()
    end

    defp maybe_create_contract_module(igniter) do
      case igniter.args.options[:module] do
        mod_str when is_binary(mod_str) and mod_str != "" ->
          module_name = ProjectModule.parse(mod_str)
          app_name = Application.app_name(igniter)

          igniter
          |> ProjectModule.find_and_update_or_create_module(
            module_name,
            """
            use JevDSL,
              otp_app: :#{app_name},
              cache: JevDSL.Cache.ETS

            defnoul :is_actionable do
              "Does this item require follow-up action?"
            end
            """,
            fn zipper -> {:ok, zipper} end
          )
          |> Igniter.add_notice("Created JevDSL contract module #{inspect(module_name)}.")

        _ ->
          igniter
      end
    end
  end
else
  defmodule Mix.Tasks.JevDsl.Install do
    @shortdoc "Installs JevDSL. Invoke with `mix igniter.install jev_dsl`."
    @moduledoc @shortdoc
    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'jev_dsl.install' requires `:igniter` to be configured as a dependency.
      Please add `{:igniter, "~> 0.8", only: [:dev, :test], runtime: false}` to your `mix.exs`.
      """)

      exit({:shutdown, 1})
    end
  end
end
