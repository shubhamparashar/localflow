import Foundation
import Testing
@testable import LocalFlow

/// Pure-logic tests only — no audio, no network, no AX. File-backed units
/// (snippets, glossary) are pointed at a per-suite temp directory; the suite
/// is serialized because those path overrides are process-global statics.
@Suite(.serialized)
final class PureLogicTests {

    private let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        SnippetsEngine.fileURL = tempDir.appendingPathComponent("snippets.json")
        Glossary.fileURL = tempDir.appendingPathComponent("glossary.txt")
        CorrectionWatcher.suggestionsFile = tempDir.appendingPathComponent("glossary-suggestions.txt")
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Snippet expansion

    private func writeSnippets(_ json: String) throws {
        try json.write(to: SnippetsEngine.fileURL, atomically: true, encoding: .utf8)
    }

    @Test func snippetFullMatchReplacesVerbatim() throws {
        try writeSnippets(#"{"snippets":[{"trigger":"my work email","expansion":"shubham.p@joinfleek.com"}]}"#)
        #expect(SnippetsEngine.apply("My work email.") == "shubham.p@joinfleek.com")
    }

    @Test func snippetInSentenceWholeWordOnly() throws {
        try writeSnippets(#"{"snippets":[{"trigger":"my work email","expansion":"shubham.p@joinfleek.com"}]}"#)
        #expect(SnippetsEngine.apply("Send it to my work email please")
            == "Send it to shubham.p@joinfleek.com please")
        try writeSnippets(#"{"snippets":[{"trigger":"cat","expansion":"dog"}]}"#)
        #expect(SnippetsEngine.apply("concatenate the cat") == "concatenate the dog")
    }

    @Test func snippetNoMatchPassesThrough() throws {
        try writeSnippets(#"{"snippets":[{"trigger":"my work email","expansion":"x"}]}"#)
        #expect(SnippetsEngine.apply("nothing to expand here") == "nothing to expand here")
    }

    // MARK: - Glossary promotion (2-sightings rule)

    @Test func glossaryPromotionAfterTwoSightings() {
        Glossary.ensureFileExists()
        CorrectionWatcher.registerSightings(["Kysely"])
        #expect(!Glossary.terms().contains("Kysely"), "one sighting must not promote")
        let suggestions = (try? String(contentsOf: CorrectionWatcher.suggestionsFile, encoding: .utf8)) ?? ""
        #expect(suggestions.contains("Kysely\t1"))

        CorrectionWatcher.registerSightings(["Kysely"])
        #expect(Glossary.terms().contains("Kysely"), "second sighting promotes")
        let after = (try? String(contentsOf: CorrectionWatcher.suggestionsFile, encoding: .utf8)) ?? ""
        #expect(!after.contains("Kysely"), "promoted term leaves the suggestions file")
    }

    @Test func glossaryKnownTermIsNotResuggested() {
        try? "Fleek\n".write(to: Glossary.fileURL, atomically: true, encoding: .utf8)
        CorrectionWatcher.registerSightings(["fleek"])
        let suggestions = (try? String(contentsOf: CorrectionWatcher.suggestionsFile, encoding: .utf8)) ?? ""
        #expect(!suggestions.contains("fleek"))
    }

    // MARK: - Cleanup guards

    @Test func guardsAcceptFaithfulCleanup() {
        let raw = "um so basically the meeting is at four pm tomorrow and we should prepare the slides"
        let cleaned = "The meeting is at 4 pm tomorrow and we should prepare the slides."
        #expect(OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned))
    }

    @Test func guardsRejectResponderModeGrowth() {
        let raw = "what time is the meeting tomorrow can you check"
        let cleaned = String(repeating: "The meeting tomorrow is scheduled at 4pm. ", count: 10)
        #expect(!OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned), "length ratio guard")
    }

    @Test func guardsRejectLowWordOverlap() {
        let raw = "please review the quarterly budget spreadsheet before friday afternoon standup meeting"
        let cleaned = "Certainly! Some totally different words about another topic entirely instead, honestly."
        #expect(!OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned), "overlap guard")
    }

    @Test func guardsRejectOverAggressiveShrink() {
        let raw = String(repeating: "we talked about the roadmap and the hiring plan today. ", count: 4)
        let cleaned = "Roadmap."
        #expect(!OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned))
    }

    @Test func wordOverlapEmptyRawIsFull() {
        #expect(OllamaCleaner.wordOverlap(raw: "a an it", cleaned: "whatever") == 1.0)
    }

    // MARK: - Long-take sentence chunker

    @Test func sentenceWindowsPackWholeSentences() {
        let s1 = "This is the first sentence about something."
        let s2 = "Here comes a second sentence with more words in it."
        let s3 = "And finally a third one to overflow the window."
        let windows = OllamaCleaner.sentenceWindows(s1 + " " + s2 + " " + s3, maxLength: 100)
        #expect(windows.count == 2)
        #expect(windows[0].contains("first sentence"))
        #expect(windows[0].contains("second sentence"))
        #expect(windows[1].contains("third one"))
    }

    @Test func sentenceWindowsOversizedSentenceIsOwnWindow() {
        let long = "this single sentence just keeps going and going without any terminal punctuation at all "
            + "so it cannot be split on a boundary and must become its own window even though it is oversized"
        let windows = OllamaCleaner.sentenceWindows("Short one. " + long, maxLength: 50)
        #expect(windows.first == "Short one.")
        #expect(windows.count >= 2)
    }

    @Test func sentenceWindowsShortTextSingleWindow() {
        #expect(OllamaCleaner.sentenceWindows("Just one.", maxLength: 500) == ["Just one."])
    }

    // MARK: - Cleanup levels & styles

    @Test func cleanupLevelsProduceDistinctPrompts() {
        let light = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .light)
        let medium = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .medium)
        let high = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .high)
        let code = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .medium, style: .code)
        #expect(Set([light, medium, high, code]).count == 4)
        #expect(!light.contains("homophones"), "light skips error correction")
        #expect(medium.contains("homophones"))
        #expect(high.contains("Smooth awkward grammar"))
        #expect(!medium.contains("Smooth awkward grammar"))
    }

    @Test func noneLevelBypassesOllamaEntirely() async {
        let savedEnabled = Config.cleanupEnabled
        let savedLevel = Config.cleanupLevel
        Config.cleanupEnabled = true
        Config.cleanupLevel = .none
        defer {
            Config.cleanupEnabled = savedEnabled
            Config.cleanupLevel = savedLevel
        }
        let raw = String(repeating: "some transcript text well over the minimum length. ", count: 3)
        // No Ollama server runs in tests: an immediate raw-text completion
        // proves the bypass (a real request would only fall back to raw after
        // a network failure/timeout).
        let started = Date()
        let result: String = await withCheckedContinuation { cont in
            OllamaCleaner.clean(raw) { cont.resume(returning: $0) }
        }
        #expect(result == raw)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test func cleanupLevelRoundTripsThroughConfig() {
        let saved = Config.cleanupLevel
        defer { Config.cleanupLevel = saved }
        for level in CleanupLevel.allCases {
            Config.cleanupLevel = level
            #expect(Config.cleanupLevel == level)
            #expect(UserDefaults.standard.string(forKey: "cleanupLevel") == level.rawValue)
        }
    }

    @Test func codeStylePromptPreservesIdentifiers() {
        let prompt = OllamaCleaner.cleanupSystemPrompt(glossary: ["Kysely"], level: .medium, style: .code)
        #expect(prompt.contains("camelCase"))
        #expect(prompt.contains("snake_case"))
        #expect(prompt.contains("Never alter the casing"))
        #expect(prompt.contains("Kysely"), "glossary bias included like the normal prompt")
    }

    @Test func guardsAcceptFaithfulCodeStyleCleanup() {
        let raw = "um so rename the get_user_id function to fetchUserId and update the snake_case call sites"
        let cleaned = "Rename the get_user_id function to fetchUserId and update the snake_case call sites."
        #expect(OllamaCleaner.guardsAccept(raw: raw, cleaned: cleaned))
    }

    @Test func codeCategoryDefaultsToCodeStyle() {
        let profile = AppContext.lookupProfile(
            bundleId: "com.apple.Terminal",
            mapping: ["com.apple.Terminal": CategoryMappingEntry(category: "code", style: nil)]
        )
        #expect(profile.category == "code")
        #expect(profile.styleOverride == .code)
        #expect(profile.cleanupEnabled)
    }

    @Test func mappingStyleOverrideWinsAndLegacyStringsParse() throws {
        let json = #"{"com.apple.mail": "email", "com.microsoft.VSCode": {"category": "code", "style": "casual"}}"#
        let mapping = try #require(AppContext.parseMapping(Data(json.utf8)))
        let mail = AppContext.lookupProfile(bundleId: "com.apple.mail", mapping: mapping)
        #expect(mail.category == "email")
        #expect(mail.styleOverride == nil)
        let vscode = AppContext.lookupProfile(bundleId: "com.microsoft.VSCode", mapping: mapping)
        #expect(vscode.styleOverride == .casual)
    }

    // MARK: - Edit distance (glossary diffing)

    @Test func editDistance() {
        #expect(CorrectionWatcher.editDistance("kysely", "kysley") == 2)
        #expect(CorrectionWatcher.editDistance("same", "same") == 0)
        #expect(CorrectionWatcher.editDistance("abcdefgh", "xyz") == Int.max)
    }

    // MARK: - Transcription routing

    @Test func routingEnglishWithParakeetReadyUsesParakeet() {
        let decision = TranscriptionRouter.route(language: "en", parakeetReady: true)
        #expect(decision == .init(engine: .parakeet, whisperLanguage: nil))
    }

    @Test func routingEnglishWithoutParakeetFallsBackToWhisper() {
        let decision = TranscriptionRouter.route(language: "en", parakeetReady: false)
        #expect(decision == .init(engine: .whisper, whisperLanguage: "en"))
    }

    @Test func routingHindiUsesWhisperWithHindiCode() {
        let decision = TranscriptionRouter.route(language: "hi", parakeetReady: true)
        #expect(decision == .init(engine: .whisper, whisperLanguage: "hi"))
    }

    @Test func routingAutoUsesWhisperWithNoLanguage() {
        let decision = TranscriptionRouter.route(language: "auto", parakeetReady: true)
        #expect(decision == .init(engine: .whisper, whisperLanguage: nil))
    }

    @Test func routingFrenchUsesWhisperWithFrenchCode() {
        let decision = TranscriptionRouter.route(language: "fr", parakeetReady: true)
        #expect(decision == .init(engine: .whisper, whisperLanguage: "fr"))
    }

    @Test func routingHinglishUsesWhisperWithHinglishCode() {
        // "hinglish" isn't a real whisper language code — Transcriber special-cases
        // it (English decode + romanized seed prompt) — routing must still hand it
        // to whisper, untouched, so that special case fires downstream.
        let decision = TranscriptionRouter.route(language: "hinglish", parakeetReady: true)
        #expect(decision == .init(engine: .whisper, whisperLanguage: "hinglish"))
    }

    // MARK: - Config persistence

    @Test func whisperLanguagePersistsAcrossReads() {
        let original = Config.whisperLanguage
        defer { Config.whisperLanguage = original }
        Config.whisperLanguage = "fr"
        #expect(Config.whisperLanguage == "fr")
        Config.whisperLanguage = "auto"
        #expect(Config.whisperLanguage == "auto")
    }

    @Test func whisperLanguagesTableCoversFullRange() {
        #expect(Config.whisperLanguages.count > 90)
        #expect(Config.whisperLanguages.contains { $0.code == "fr" && $0.name == "French" })
        #expect(!Config.whisperLanguages.contains { $0.code == "hinglish" }, "pseudo-language is not a real whisper code")
    }

    // MARK: - Quiet mode recording profile

    @Test func normalProfileMatchesBaselineParameters() {
        let profile = AudioRecorder.recordingProfile(quietModeEnabled: false)
        #expect(profile.gain == 1.0)
        #expect(profile.vadOffsetDb == 12)
        #expect(profile.vadFloorDb == -55)
    }

    @Test func quietProfileBoostsGainAndLowersVadThreshold() {
        let normal = AudioRecorder.recordingProfile(quietModeEnabled: false)
        let quiet = AudioRecorder.recordingProfile(quietModeEnabled: true)
        #expect(quiet.gain > normal.gain * 1.4)
        #expect(quiet.gain < normal.gain * 2.1)
        #expect(quiet.vadOffsetDb < normal.vadOffsetDb)
        #expect(quiet.vadFloorDb < normal.vadFloorDb)
    }

    // MARK: - Language recents / badge / per-app memory

    @Test func recentsAddsNewCodeToFront() {
        #expect(Config.updatedRecents([], selecting: "en") == ["en"])
        #expect(Config.updatedRecents(["en"], selecting: "fr") == ["fr", "en"])
    }

    @Test func recentsDedupesExistingCode() {
        #expect(Config.updatedRecents(["en", "fr", "hi"], selecting: "fr") == ["fr", "en", "hi"])
    }

    @Test func recentsCapsAtThree() {
        #expect(Config.updatedRecents(["en", "fr", "hi"], selecting: "auto") == ["auto", "en", "fr"])
    }

    @Test func nextLanguageWrapsAroundRecents() {
        #expect(Config.nextLanguage(after: "en", in: ["en", "fr", "hi"]) == "fr")
        #expect(Config.nextLanguage(after: "hi", in: ["en", "fr", "hi"]) == "en")
    }

    @Test func nextLanguageFallsBackWhenCurrentNotInRecents() {
        #expect(Config.nextLanguage(after: "auto", in: ["en", "fr"]) == "en")
    }

    @Test func nextLanguageNoOpWhenRecentsEmpty() {
        #expect(Config.nextLanguage(after: "en", in: []) == "en")
    }

    @Test func languageBadgeDerivation() {
        #expect(Config.languageBadge(for: "en") == "EN")
        #expect(Config.languageBadge(for: "auto") == "A")
        #expect(Config.languageBadge(for: "hinglish") == "HG")
        #expect(Config.languageBadge(for: "fr") == "FR")
    }

    @Test func perAppLanguageDisabledReturnsNil() {
        #expect(Config.perAppLanguage(enabled: false, map: ["com.apple.mail": "fr"], bundleId: "com.apple.mail") == nil)
    }

    @Test func perAppLanguageMissingBundleReturnsNil() {
        #expect(Config.perAppLanguage(enabled: true, map: ["com.apple.mail": "fr"], bundleId: nil) == nil)
        #expect(Config.perAppLanguage(enabled: true, map: [:], bundleId: "com.apple.mail") == nil)
    }

    @Test func perAppLanguageEnabledReturnsRememberedCode() {
        #expect(Config.perAppLanguage(enabled: true, map: ["com.apple.mail": "fr"], bundleId: "com.apple.mail") == "fr")
    }

    // MARK: - Partial-caption tick scheduler

    @Test func partialTickSkipsBeforeThreshold() {
        #expect(!PartialCaptionScheduler.shouldRunTick(elapsedSamples: 8_000, samplesPerTick: 16_000, inFlight: false))
    }

    @Test func partialTickRunsAtThresholdWhenIdle() {
        #expect(PartialCaptionScheduler.shouldRunTick(elapsedSamples: 16_000, samplesPerTick: 16_000, inFlight: false))
        #expect(PartialCaptionScheduler.shouldRunTick(elapsedSamples: 20_000, samplesPerTick: 16_000, inFlight: false))
    }

    @Test func partialTickSkipsAtThresholdWhenBusy() {
        #expect(!PartialCaptionScheduler.shouldRunTick(elapsedSamples: 16_000, samplesPerTick: 16_000, inFlight: true))
    }

    // MARK: - FieldContext sanitization

    @Test func fieldContextWindowAroundCaret() {
        let text = String(repeating: "a", count: 1000)
        let window = FieldContext.sanitizedWindow(fullText: text, caretOffset: 500, maxLength: 500)
        #expect(window.count == 500)
    }

    @Test func fieldContextNoCaretFallsBackToTail() {
        let text = String(repeating: "x", count: 10) + String(repeating: "y", count: 1000)
        let window = FieldContext.sanitizedWindow(fullText: text, caretOffset: nil, maxLength: 500)
        #expect(window.count == 500)
        #expect(window == String(repeating: "y", count: 500))
    }

    @Test func fieldContextStripsControlCharsAndCollapsesWhitespace() {
        let text = "hello\u{0007}world  with   \t\nspaces"
        let window = FieldContext.sanitizedWindow(fullText: text, caretOffset: nil, maxLength: 500)
        #expect(!window.contains("\u{0007}"))
        #expect(!window.contains("  "))
        #expect(window == "helloworld with spaces")
    }

    @Test func fieldContextEnforcesMaxLength() {
        let text = String(repeating: "z", count: 5_000)
        let window = FieldContext.sanitizedWindow(fullText: text, caretOffset: 2_500, maxLength: 500)
        #expect(window.count <= 500)
    }

    @Test func fieldContextShortTextPassesThroughUnchanged() {
        let text = "short field text"
        let window = FieldContext.sanitizedWindow(fullText: text, caretOffset: nil, maxLength: 500)
        #expect(window == text)
    }

    // MARK: - Glossary importer merge/dedupe

    @Test func importerMergeSkipsCaseInsensitiveDuplicates() {
        let added = GlossaryImporter.merge(newTerms: ["Kysely", "fleek", "Shubham"], into: ["Fleek", "Kysely"])
        #expect(added == ["Shubham"])
    }

    @Test func importerMergePreservesNewTermCasing() {
        let added = GlossaryImporter.merge(newTerms: ["FetchUserId"], into: [])
        #expect(added == ["FetchUserId"])
    }

    @Test func importerMergeDedupesWithinNewTermsToo() {
        let added = GlossaryImporter.merge(newTerms: ["Priya", "priya", "Rohan"], into: [])
        #expect(added == ["Priya", "Rohan"])
    }

    @Test func importerMergeIgnoresEmptyStrings() {
        #expect(GlossaryImporter.merge(newTerms: ["", "Term"], into: []) == ["Term"])
    }

    // MARK: - Glossary importer identifier ranking

    @Test func topIdentifiersRanksByFrequencyThenAlphabetically() {
        let corpus = [
            "fetchUserId fetchUserId get_user_name",
            "fetchUserId get_user_name get_user_name",
        ]
        #expect(GlossaryImporter.topIdentifiers(in: corpus, top: 2) == ["fetchUserId", "get_user_name"])
    }

    @Test func topIdentifiersRespectsTopLimit() {
        let corpus = ["fetchUserId get_user_name renderPageHeader"]
        #expect(GlossaryImporter.topIdentifiers(in: corpus, top: 1).count == 1)
    }

    @Test func identifiersExtractCamelAndSnakeCaseOnlyAboveMinLength() {
        let text = "let x = a; fetchUserId(); let get_user = 1; let ab = 2;"
        let found = GlossaryImporter.identifiers(in: text)
        #expect(found.contains("fetchUserId"))
        #expect(!found.contains("ab"), "below minimum length")
        #expect(!found.contains("x"), "plain short identifier is not camel or snake case")
    }

    // MARK: - Prompt assembly with field context

    @Test func cleanupPromptIncludesFieldContextWithReferenceOnlyInstruction() {
        var system = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .medium)
        let fieldContext = "Dear Priyanka, following up on the invoice"
        system += "\n\nContext already in the user's document (for spelling/proper nouns only, do NOT include it in the output):\n\(fieldContext)"
        #expect(system.contains(fieldContext))
        #expect(system.contains("do NOT include it in the output"))
    }

    @Test func cleanupPromptWithoutFieldContextIsUnchanged() {
        let withoutContext = OllamaCleaner.cleanupSystemPrompt(glossary: [], level: .medium)
        #expect(!withoutContext.contains("Context already in the user's document"))
    }

    // MARK: - Claude pipe

    @Test func claudePipeSubstitutesPlaceholderWithEnvReference() {
        let invocation = ClaudePipe.buildInvocation(command: "claude -p {text}", transcript: "hello world")
        #expect(invocation.executable == "/bin/zsh")
        #expect(invocation.arguments == ["-lc", "claude -p \"$LOCALFLOW_TEXT\""])
        #expect(invocation.environment["LOCALFLOW_TEXT"] == "hello world")
        #expect(!invocation.arguments.joined().contains("hello world"), "transcript must never appear in the shell line itself")
    }

    @Test func claudePipeCustomCommandTemplateSubstitutesInPlace() {
        let invocation = ClaudePipe.buildInvocation(command: "echo start && claude -p {text} | tee out.txt", transcript: "x")
        #expect(invocation.arguments == ["-lc", "echo start && claude -p \"$LOCALFLOW_TEXT\" | tee out.txt"])
    }

    @Test func claudePipeInjectionAttemptStaysInertAsEnvValue() {
        let malicious = "\"; rm -rf ~; echo \""
        let invocation = ClaudePipe.buildInvocation(command: "claude -p {text}", transcript: malicious)
        // The dangerous payload must land only in the environment dictionary,
        // never spliced into the shell command line where it could execute.
        #expect(invocation.arguments == ["-lc", "claude -p \"$LOCALFLOW_TEXT\""])
        #expect(invocation.environment["LOCALFLOW_TEXT"] == malicious)
        #expect(!invocation.arguments.joined().contains("rm -rf"))
    }

    @Test func claudePipeBacktickAndDollarStayInertAsEnvValue() {
        let payload = "`whoami` $(id) $HOME"
        let invocation = ClaudePipe.buildInvocation(command: "claude -p {text}", transcript: payload)
        #expect(invocation.environment["LOCALFLOW_TEXT"] == payload)
        #expect(!invocation.arguments.joined().contains("whoami"))
    }

    // MARK: - Dictation routing (command / claude-pipe / normal)

    @Test func routeCommandTakesPrecedence() {
        #expect(DictationRoute.decide(isCommand: true, isClaudePipe: true) == .command)
        #expect(DictationRoute.decide(isCommand: true, isClaudePipe: false) == .command)
    }

    @Test func routeClaudePipeSkipsCleanupAndInjection() {
        #expect(DictationRoute.decide(isCommand: false, isClaudePipe: true) == .claudePipe)
    }

    @Test func routeNormalWhenNeitherFlagSet() {
        #expect(DictationRoute.decide(isCommand: false, isClaudePipe: false) == .normal)
    }

    // MARK: - Snippet slots

    @Test func fillSlotsSubstitutesClipboardAndDate() {
        let date = Date(timeIntervalSince1970: 0)
        let expected = DateFormatter()
        expected.dateStyle = .medium
        expected.timeStyle = .none
        let result = SnippetsEngine.fillSlots(
            expansion: "Paste: {clipboard} on {date}",
            clipboard: "COPIED",
            date: date
        )
        #expect(result.text == "Paste: COPIED on \(expected.string(from: date))")
        #expect(result.cursorOffsetFromEnd == nil)
    }

    @Test func fillSlotsCursorMiddleReturnsOffsetFromEnd() {
        let result = SnippetsEngine.fillSlots(expansion: "Hi {cursor}, bye", clipboard: "", date: Date())
        #expect(result.text == "Hi , bye")
        #expect(result.cursorOffsetFromEnd == 5)
    }

    @Test func fillSlotsCursorAtEndIsZeroAndAtStartIsFullLength() {
        let end = SnippetsEngine.fillSlots(expansion: "done{cursor}", clipboard: "", date: Date())
        #expect(end.text == "done")
        #expect(end.cursorOffsetFromEnd == 0)
        let start = SnippetsEngine.fillSlots(expansion: "{cursor}done", clipboard: "", date: Date())
        #expect(start.text == "done")
        #expect(start.cursorOffsetFromEnd == 4)
    }

    @Test func fillSlotsOnlyFirstCursorCountsAndNoPlaceholdersPassThrough() {
        let multi = SnippetsEngine.fillSlots(expansion: "a{cursor}b{cursor}c", clipboard: "", date: Date())
        #expect(multi.text == "abc")
        #expect(multi.cursorOffsetFromEnd == 2)
        let plain = SnippetsEngine.fillSlots(expansion: "no placeholders", clipboard: "x", date: Date())
        #expect(plain.text == "no placeholders")
        #expect(plain.cursorOffsetFromEnd == nil)
    }

    // MARK: - Capture mode

    @Test func captureRouteAndPrecedence() {
        #expect(DictationRoute.decide(isCommand: false, isClaudePipe: false, isCapture: true) == .capture)
        #expect(DictationRoute.decide(isCommand: true, isClaudePipe: false, isCapture: true) == .command)
        #expect(DictationRoute.decide(isCommand: false, isClaudePipe: true, isCapture: true) == .claudePipe)
    }

    @Test func captureRestartsOnlyWhileActiveAndForCaptureTakes() {
        #expect(DictationRoute.shouldRestartCapture(captureActive: true, wasCapture: true))
        #expect(!DictationRoute.shouldRestartCapture(captureActive: false, wasCapture: true))
        #expect(!DictationRoute.shouldRestartCapture(captureActive: true, wasCapture: false))
    }

    // MARK: - Redaction guard

    private func kinds(_ text: String) -> Set<String> {
        Set(RedactionGuard.findSecrets(in: text).map(\.kind))
    }

    @Test func redactionDetectsGitHubToken() {
        #expect(kinds("here is ghp_abcdefghij1234567890XYZa ok") == ["github-token"])
        #expect(kinds("token github_pat_11ABCDEFG0abcdefghij1234").contains("github-token"))
    }

    @Test func redactionDetectsAWSKey() {
        #expect(kinds("key AKIAIOSFODNN7EXAMPLE in env") == ["aws-access-key"])
    }

    @Test func redactionDetectsSkStyleKey() {
        #expect(kinds("use sk-ant-api03-abcdefghijklmnopqrst please") == ["api-key"])
    }

    @Test func redactionDetectsSlackToken() {
        #expect(kinds("xoxb-1234567890-abcdef") == ["slack-token"])
    }

    @Test func redactionDetectsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abc12"
        #expect(kinds(jwt) == ["jwt"])
    }

    @Test func redactionDetectsPrivateKeyHeader() {
        #expect(kinds("-----BEGIN RSA PRIVATE KEY-----") == ["private-key"])
        #expect(kinds("-----BEGIN PRIVATE KEY-----") == ["private-key"])
    }

    @Test func redactionGenericRuleNeedsKeywordNearby() {
        let hex = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        #expect(kinds("the api_key is \(hex)") == ["generic-secret"])
        #expect(kinds("my password: dGhpc2lzYXNlY3JldHZhbHVlMTIzNDU2Nzg5MGFi").contains("generic-secret"))
        // Same blob with no keyword within reach must NOT match.
        #expect(kinds("checksum of the download was \(hex)").isEmpty)
    }

    @Test func redactionIgnoresCleanText() {
        #expect(kinds("Let's meet tomorrow at 3pm to discuss the quarterly roadmap.").isEmpty)
        #expect(kinds("see https://example.com/some/really/long/path/segment/abcdefghijklmnopqrstuvwxyz-page").isEmpty)
        // A 40-char ordinary word.
        #expect(kinds("pneumonoultramicroscopicsilicovolcanoconiosis is a long word").isEmpty)
    }
}

// MARK: - Decode-loop collapse & capture language

@Suite struct TranscriptQualityTests {
    @Test func collapseShrinksTriplePlusRuns() {
        let text = "I was doing a lot of migration. I was doing a lot of migration. "
            + "I was doing a lot of migration. I was doing a lot of migration. Then it worked."
        let out = Transcriber.collapseRepeatedSentences(text)
        #expect(out == "I was doing a lot of migration. Then it worked.")
    }

    @Test func collapseKeepsDoubleRepeats() {
        let text = "No. No. Please stop."
        #expect(Transcriber.collapseRepeatedSentences(text) == text)
    }

    @Test func collapseLeavesNormalTextUntouched() {
        let text = "First sentence here. A second one follows. And a third closes it."
        #expect(Transcriber.collapseRepeatedSentences(text) == text)
    }

    @Test func collapseIsCaseAndWhitespaceInsensitive() {
        let text = "We can't do it.  we can't do it. WE CAN'T DO IT. Fine."
        #expect(Transcriber.collapseRepeatedSentences(text) == "We can't do it. Fine.")
    }

    @Test func captureLanguageResolution() {
        let saved = Config.captureLanguage
        defer { Config.captureLanguage = saved }
        Config.captureLanguage = "auto"
        #expect(Config.effectiveCaptureLanguage(dictationLanguage: "en") == "auto")
        Config.captureLanguage = "same"
        #expect(Config.effectiveCaptureLanguage(dictationLanguage: "hinglish") == "hinglish")
        Config.captureLanguage = "hinglish"
        #expect(Config.effectiveCaptureLanguage(dictationLanguage: "en") == "hinglish")
    }
}
