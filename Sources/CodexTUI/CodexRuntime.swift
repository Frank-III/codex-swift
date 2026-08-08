import Foundation
import KWWKAI
import KWWKAgent
import TermLoomSyntaxHighlighting

public enum CodexRuntime {
  @MainActor
  public static func demo(
    directory: String = FileManager.default.currentDirectoryPath
  ) -> CodexApplication {
    let systemServices = CodexSystemServices.live
    let keymapResult = Result {
      try CodexRuntimeKeymap(configuration: CodexSettingsStore().keymap())
    }
    let keymap = (try? keymapResult.get()) ?? (try! CodexRuntimeKeymap())
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        model: "demo", reasoningEffort: "simulated", directory: directory),
      runtimeKeymap: keymap)
    if case .failure(let error) = keymapResult {
      model.entries.append(
        TranscriptEntry(
          content: .error("Invalid 'tui.keymap' configuration: \(error.localizedDescription)")))
    }
    return CodexApplication(
      model: model, driver: CodexDemoDriver(model: model), systemServices: systemServices)
  }

  @MainActor
  public static func live(
    directory: String = FileManager.default.currentDirectoryPath,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> CodexApplication {
    let systemServices = CodexSystemServices.live
    let piCodex = await loadPiCodex(environment: environment)
    let availableModels: [Model]
    let authResolver: (@Sendable (Model, String?) async throws -> ResolvedProviderAuth?)?
    if let piCodex {
      availableModels = piCodex.models
      authResolver = piCodex.authResolver
    } else {
      await registerBuiltinsFromEnvironment(env: environment)
      availableModels = authenticatedModels(environment: environment)
      authResolver = nil
    }
    let selectedModel = selectModel(
      from: availableModels,
      requestedProvider: environment["CODEX_SWIFT_PROVIDER"] ?? piCodex?.preferredProvider,
      requestedModel: environment["CODEX_SWIFT_MODEL"] ?? piCodex?.preferredModel)
    let thinkingLevel =
      ThinkingLevel(
        rawValue: environment["CODEX_SWIFT_REASONING"] ?? piCodex?.thinkingLevel ?? "high"
      ) ?? .high
    let contextFiles = loadContextFiles(in: directory)
    let skillDirectories = defaultSkillDirectories(
      directory: directory, environment: environment)
    let availableSkills = Skills.load(directories: skillDirectories).skills
      .filter { !$0.disableModelInvocation }
      .map { SkillSummary(name: $0.name, description: $0.description, path: $0.path) }
    let backgroundManager = BackgroundTaskManager()
    var config = CodingAgentConfig(
      model: selectedModel,
      cwd: directory,
      tools: .standard,
      contextFiles: contextFiles,
      skillDirectories: skillDirectories,
      backgroundManager: backgroundManager,
      backgroundAutoContinue: true,
      authResolver: authResolver,
      bashEnvironment: environment
    )
    config.useBuiltinSubagents()
    let codingAgent = await makeCodingAgent(config)
    let requestedThinking = ModelThinkingLevel(rawValue: thinkingLevel.rawValue) ?? .medium
    let supportedThinking = clampThinkingLevel(selectedModel, requestedThinking)
    let effectiveThinkingLevel = ThinkingLevel(rawValue: supportedThinking.rawValue) ?? .off
    codingAgent.agent.state.thinkingLevel = effectiveThinkingLevel
    let keymapResult: Result<CodexRuntimeKeymap, Error>
    do {
      keymapResult = .success(
        try CodexRuntimeKeymap(configuration: await systemServices.loadKeymap()))
    } catch {
      keymapResult = .failure(error)
    }
    let runtimeKeymap = (try? keymapResult.get()) ?? (try! CodexRuntimeKeymap())
    let model = CodexSessionModel(
      snapshot: CodexSnapshot(
        model: selectedModel.id,
        modelProvider: selectedModel.provider,
        reasoningEffort: effectiveThinkingLevel.rawValue,
        syntaxTheme: (try? await systemServices.loadSyntaxTheme())
          ?? SyntaxTheme.named(SyntaxTheme.defaultName)!,
        rawOutputMode: (try? await systemServices.loadRawOutputMode()) ?? false,
        directory: directory
      ), runtimeKeymap: runtimeKeymap)
    if case .failure(let error) = keymapResult {
      model.entries.append(
        TranscriptEntry(
          content: .error("Invalid 'tui.keymap' configuration: \(error.localizedDescription)")))
    }
    let sessionDirectory = URL(
      fileURLWithPath: environment["CODEX_SWIFT_HOME"]
        ?? environment["HOME"].map { "\($0)/.codex-swift" }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("codex-swift").path
    ).appendingPathComponent("sessions", isDirectory: true)
    let sessionStore = CodexSessionTreeStore(directory: sessionDirectory)
    let factory: @MainActor @Sendable (String, Model, [Message]) async -> CodingAgent = {
      sessionID, selected, messages in
      var replacementConfig = config
      replacementConfig.sessionId = sessionID
      replacementConfig.model = selected
      let replacement = await makeCodingAgent(replacementConfig)
      replacement.agent.state.messages = messages
      return replacement
    }
    return CodexApplication(
      model: model,
      driver: CodexAgentDriver(
        codingAgent: codingAgent, model: model, availableModels: availableModels,
        sessionStore: sessionStore, backgroundManager: backgroundManager,
        availableSkills: availableSkills, agentFactory: factory),
      systemServices: systemServices
    )
  }

  private struct PiCodexConfiguration: Sendable {
    var models: [Model]
    var preferredProvider: String?
    var preferredModel: String?
    var thinkingLevel: String?
    var authResolver: @Sendable (Model, String?) async throws -> ResolvedProviderAuth?
  }

  /// Load every runnable model exposed by pi's credential and generated-model stores without
  /// copying or rewriting either file. OAuth tokens refresh through KWWK's in-memory store.
  private static func loadPiCodex(
    environment: [String: String]
  ) async -> PiCodexConfiguration? {
    guard let home = environment["HOME"] else { return nil }
    let agentDirectory = environment["PI_CODING_AGENT_DIR"] ?? "\(home)/.pi/agent"
    let authURL = URL(fileURLWithPath: agentDirectory).appendingPathComponent("auth.json")
    guard let data = try? Data(contentsOf: authURL),
      let authRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    var staticKeys: [String: String] = authRoot.compactMapValues { raw in
      guard let entry = raw as? [String: Any], entry["type"] as? String == "api_key",
        let key = entry["key"] as? String, !key.isEmpty
      else { return nil }
      return key
    }
    let environmentCredentials = [
      "openai": environment["OPENAI_API_KEY"],
      "anthropic": environment["ANTHROPIC_API_KEY"],
      "google": environment["GOOGLE_API_KEY"] ?? environment["GEMINI_API_KEY"],
      "xai": environment["XAI_API_KEY"],
      "groq": environment["GROQ_API_KEY"],
      "openrouter": environment["OPENROUTER_API_KEY"],
      "zai": environment["ZAI_API_KEY"],
    ]
    for (provider, key) in environmentCredentials {
      if let key, !key.isEmpty { staticKeys[provider] = key }
    }
    var oauthTokenResolvers: [String: @Sendable () async throws -> String] = [:]
    var oauthAccountIDs: [String: String] = [:]
    for (scope, rawEntry) in authRoot {
      guard let entry = rawEntry as? [String: Any], entry["type"] as? String == "oauth",
        let access = entry["access"] as? String,
        let refresh = entry["refresh"] as? String,
        let expires = (entry["expires"] as? NSNumber)?.int64Value
      else { continue }
      let oauthProvider: String?
      if scope == "anthropic" {
        oauthProvider = "anthropic"
      } else if scope.hasPrefix("openai-codex") {
        oauthProvider = "openai-codex"
      } else {
        oauthProvider = nil
      }
      guard let oauthProvider else { continue }
      var extras: [String: JSONValue] = [:]
      if let accountID = entry["accountId"] as? String {
        extras["accountId"] = .string(accountID)
        oauthAccountIDs[scope] = accountID
      }
      let accountStore = OAuthStore()
      try? await accountStore.set(
        OAuthCredentials(access: access, refresh: refresh, expires: expires, extras: extras),
        for: oauthProvider)
      let accountManager = OAuthManager(store: accountStore)
      oauthTokenResolvers[scope] = {
        try await accountManager.apiKey(for: oauthProvider)
      }
    }

    let modelStoreURL = URL(fileURLWithPath: agentDirectory).appendingPathComponent(
      "models-store.json")
    let modelRoot =
      (try? Data(contentsOf: modelStoreURL)).flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      } ?? [:]
    func storedModels(for provider: String) -> [Model] {
      guard let providerObject = modelRoot[provider] as? [String: Any],
        let rawModels = providerObject["models"],
        let encoded = try? JSONSerialization.data(withJSONObject: rawModels)
      else { return [] }
      return (try? JSONDecoder().decode([Model].self, from: encoded)) ?? []
    }

    var models: [Model] = []
    for provider in staticKeys.keys.sorted() {
      let stored = storedModels(for: provider)
      let catalog = stored.isEmpty ? ModelsCatalog.models(for: provider) : stored
      let supportedAPIs = await registerScopedStaticProviders(
        provider: provider, apiKey: staticKeys[provider]!, models: catalog)
      models += catalog.filter { supportedAPIs.contains($0.api) }
    }
    for provider in ["openai", "anthropic", "google"]
    where authenticatedProvider(
      provider, environment: environment)
    {
      models += ModelsCatalog.models(for: provider)
    }
    if oauthTokenResolvers["anthropic"] != nil {
      models += ModelsCatalog.models(for: "anthropic")
    }
    let storedCodexModels = storedModels(for: "openai-codex")
    let codexCatalog =
      storedCodexModels.isEmpty ? ModelsCatalog.models(for: "openai-codex") : storedCodexModels
    for scope in oauthTokenResolvers.keys.filter({ $0.hasPrefix("openai-codex") }).sorted() {
      await APIRegistry.shared.register(
        ProviderVariants.chatgptCodex(
          accountId: oauthAccountIDs[scope], originator: "codex-swift"),
        scope: scope)
      models += codexCatalog.map { model in
        Model(
          id: model.id, name: model.name, api: "chatgpt-codex", provider: scope,
          baseURL: "https://chatgpt.com", reasoning: model.reasoning, input: model.input,
          cost: model.cost, contextWindow: model.contextWindow, maxTokens: 0,
          compat: model.compat, thinkingLevelMap: model.thinkingLevelMap)
      }
    }

    let openAICompatibleKey =
      environment["OPENAI_API_KEY"]
      ?? staticKeys["openai"]
      ?? staticKeys.first(where: { provider, _ in
        storedModels(for: provider).contains { $0.api.hasPrefix("openai-") }
      })?.value
    let anthropicKey =
      environment["ANTHROPIC_API_KEY"]
      ?? staticKeys["anthropic"]
      ?? staticKeys.first(where: { provider, _ in
        storedModels(for: provider).contains { $0.api == "anthropic-messages" }
      })?.value
    let googleKey =
      environment["GOOGLE_API_KEY"] ?? environment["GEMINI_API_KEY"]
      ?? staticKeys["google"]
    _ = await registerBuiltins(
      anthropic: anthropicKey, openaiCompletions: openAICompatibleKey,
      openaiResponses: openAICompatibleKey, google: googleKey,
      sourceId: "codex-swift-pi-models")
    if oauthTokenResolvers["anthropic"] != nil {
      await APIRegistry.shared.register(ProviderVariants.anthropicOAuth(), scope: "anthropic")
    }

    var seen: Set<String> = []
    models = models.filter { seen.insert("\($0.provider)::\($0.id)").inserted }
    guard !models.isEmpty else { return nil }
    let settingsURL = URL(fileURLWithPath: agentDirectory).appendingPathComponent("settings.json")
    let settings = (try? Data(contentsOf: settingsURL)).flatMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }
    let availableOAuthResolvers = oauthTokenResolvers
    let resolvedStaticKeys = staticKeys
    let resolver: @Sendable (Model, String?) async throws -> ResolvedProviderAuth? = { model, _ in
      if let tokenResolver = availableOAuthResolvers[model.provider] {
        return ResolvedProviderAuth(token: try await tokenResolver(), scheme: .bearer)
      }
      guard let key = resolvedStaticKeys[model.provider] else { return nil }
      let scheme: AuthScheme =
        model.api == "google-generative-ai"
        ? .queryKey(name: "key")
        : model.api == "anthropic-messages"
          ? .apiKeyHeader(name: "x-api-key")
          : .bearer
      return ResolvedProviderAuth(token: key, scheme: scheme, baseURL: model.baseURL)
    }
    return PiCodexConfiguration(
      models: models,
      preferredProvider: settings?["defaultProvider"] as? String,
      preferredModel: settings?["defaultModel"] as? String,
      thinkingLevel: settings?["defaultThinkingLevel"] as? String,
      authResolver: resolver)
  }

  /// Register each static pi credential under its model-provider scope. Several providers share
  /// the same wire API, so a single flat OpenAI-compatible registration cannot safely serve them:
  /// KWWK deliberately rejects a flat `openai` provider when the model belongs to `deepseek`,
  /// `qwen-token-plan`, and similar vendors.
  static func registerScopedStaticProviders(
    provider: String, apiKey: String, models: [Model]
  ) async -> Set<String> {
    var supported: Set<String> = []
    for api in Set(models.map(\.api)) {
      let implementation: (any APIProvider)? =
        switch api {
        case "anthropic-messages" where provider == "kimi-coding":
          AnthropicProvider(
            api: api, defaultAPIKey: apiKey,
            authHeaderBuilder: { key in
              ["Authorization": "Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))"]
            })
        case "anthropic-messages": AnthropicProvider(api: api, defaultAPIKey: apiKey)
        case "openai-completions": OpenAICompletionsProvider(api: api, defaultAPIKey: apiKey)
        case "openai-responses": OpenAIResponsesProvider(api: api, defaultAPIKey: apiKey)
        case "google-generative-ai": GoogleGeminiProvider(api: api, defaultAPIKey: apiKey)
        case "cursor-agent": CursorAgentProvider(defaultAPIKey: apiKey)
        default: nil
        }
      guard let implementation else { continue }
      await APIRegistry.shared.register(
        implementation, scope: provider, sourceId: "codex-swift-pi-\(provider)")
      supported.insert(api)
    }
    return supported
  }

  private static func authenticatedProvider(
    _ provider: String, environment: [String: String]
  ) -> Bool {
    switch provider {
    case "openai": return !(environment["OPENAI_API_KEY"] ?? "").isEmpty
    case "anthropic": return !(environment["ANTHROPIC_API_KEY"] ?? "").isEmpty
    case "google":
      return !(environment["GOOGLE_API_KEY"] ?? environment["GEMINI_API_KEY"] ?? "").isEmpty
    default: return false
    }
  }

  /// KWWK bundles pi-mono's generated model catalog. Only surface providers
  /// for which this process has credentials, so every picker row is runnable.
  private static func authenticatedModels(environment: [String: String]) -> [Model] {
    let providers = [
      environment["OPENAI_API_KEY"].flatMap { $0.isEmpty ? nil : "openai" },
      environment["ANTHROPIC_API_KEY"].flatMap { $0.isEmpty ? nil : "anthropic" },
      (environment["GOOGLE_API_KEY"] ?? environment["GEMINI_API_KEY"])
        .flatMap { $0.isEmpty ? nil : "google" },
    ].compactMap { $0 }
    let models = providers.flatMap(ModelsCatalog.models(for:))
    // Keep startup inspectable without credentials; the first request will
    // surface KWWK's precise missing-auth error.
    return models.isEmpty ? ModelsCatalog.models(for: "openai") : models
  }

  private static func selectModel(
    from models: [Model], requestedProvider: String?, requestedModel: String?
  ) -> Model {
    let providerFiltered =
      requestedProvider.map { provider in
        models.filter { $0.provider == provider }
      }.flatMap { $0.isEmpty ? nil : $0 } ?? models
    if let requestedModel,
      let exact = providerFiltered.first(where: { $0.id == requestedModel })
    {
      return exact
    }
    let preferred =
      providerFiltered.sorted { lhs, rhs in
        if lhs.cost.output != rhs.cost.output { return lhs.cost.output > rhs.cost.output }
        if lhs.cost.input != rhs.cost.input { return lhs.cost.input > rhs.cost.input }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedDescending
      }.first(where: \.reasoning) ?? providerFiltered.first
    guard let selected = preferred else {
      preconditionFailure("KWWK's pi model catalog contains no selectable models")
    }
    return selected
  }

  private static func loadContextFiles(in directory: String) -> [(path: String, content: String)] {
    ["AGENTS.md", "CLAUDE.md"].compactMap { name in
      let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
      return (path: path, content: content)
    }
  }

  static func defaultSkillDirectories(
    directory: String, environment: [String: String]
  ) -> [String] {
    let project = URL(fileURLWithPath: directory, isDirectory: true)
    var candidates = [
      project.appendingPathComponent(".codex/skills").path,
      project.appendingPathComponent(".agents/skills").path,
      project.appendingPathComponent(".kwwk/skills").path,
      project.appendingPathComponent(".claude/skills").path,
    ]
    if let home = environment["HOME"] {
      candidates += [
        "\(home)/.codex/skills",
        "\(home)/.agents/skills",
        "\(home)/.kwwk/skills",
        environment["PI_CODING_AGENT_DIR"].map { "\($0)/skills" }
          ?? "\(home)/.pi/agent/skills",
      ]
    }
    var seen: Set<String> = []
    return candidates.filter {
      seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0)
    }
  }

}
