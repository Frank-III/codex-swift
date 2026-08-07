import KWWKAI
import Testing

@testable import CodexTUI

@Suite(.serialized)
struct CodexRuntimeTests {
  @Test func staticPiProvidersRegisterUnderTheirOwnWireScope() async {
    let provider = "codex-swift-test-deepseek"
    let model = Model(
      id: "deepseek-test", api: "openai-completions", provider: provider,
      baseURL: "https://example.invalid")

    let supported = await CodexRuntime.registerScopedStaticProviders(
      provider: provider, apiKey: "test-key", models: [model])

    #expect(supported == ["openai-completions"])
    #expect(
      await APIRegistry.shared.provider(scope: provider, api: "openai-completions") != nil)
    #expect(
      await APIRegistry.shared.provider(scope: "another-provider", api: "openai-completions")
        == nil)
    await APIRegistry.shared.unregisterScope(provider)
  }

  @Test func unsupportedPiWiresAreNotAdvertisedAsRunnable() async {
    let provider = "codex-swift-test-unsupported"
    let model = Model(id: "future", api: "future-wire", provider: provider)

    let supported = await CodexRuntime.registerScopedStaticProviders(
      provider: provider, apiKey: "test-key", models: [model])

    #expect(supported.isEmpty)
    #expect(await APIRegistry.shared.provider(scope: provider, api: "future-wire") == nil)
  }
}
