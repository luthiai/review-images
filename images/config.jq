# Raw OCI configuration, as consumed by LuthiAI's archive metadata reader.
type == "object"
and .os == "linux"
and .architecture == $arch
and (.config | type == "object")
and (.config.Env | type == "array")
and all(.config.Env[]; type == "string" and test("^[A-Za-z_][A-Za-z0-9_]*="))
and ([.config.Env[] | split("=")[0]] | length == (unique | length))
and (.config.Env | index(
  (if $agent == "claude" then "CLAUDE_CODE_EXECUTABLE" else "CODEX_PATH" end)
  + "=/usr/local/bin/" + $agent) != null)
and all(.config.Env[];
  test("^(CODEX_HOME|CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY|OPENAI_BASE_URL|OPENAI_API_KEY|ANTHROPIC_BASE_URL|ANTHROPIC_API_KEY|GH_TOKEN|GITHUB_TOKEN)=") | not)
and .config.WorkingDir == "/sandbox"
and ((.config.Entrypoint // []) | length == 0)
and .config.Cmd == ["/bin/bash"]
and .rootfs.type == "layers"
