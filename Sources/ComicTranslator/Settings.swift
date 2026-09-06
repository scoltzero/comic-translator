import Foundation
import SwiftUI

// MARK: - 语言选项

struct LanguageOption: Identifiable, Hashable {
    let id: String    // BCP-47 代码
    let name: String  // 显示名
    let chineseName: String  // HY-MT 中文 prompt 用

    static let auto = LanguageOption(id: "auto", name: "自动检测", chineseName: "")

    static let allLanguages: [LanguageOption] = [
        LanguageOption(id: "zh-Hans", name: "简体中文", chineseName: "中文"),
        LanguageOption(id: "zh-Hant", name: "繁体中文", chineseName: "繁体中文"),
        LanguageOption(id: "zh-HK", name: "粤语（广东话）", chineseName: "粤语"),
        LanguageOption(id: "en", name: "英语", chineseName: "英语"),
        LanguageOption(id: "ja", name: "日语", chineseName: "日语"),
        LanguageOption(id: "ko", name: "韩语", chineseName: "韩语"),
        LanguageOption(id: "it", name: "意大利语", chineseName: "意大利语"),
        LanguageOption(id: "fr", name: "法语", chineseName: "法语"),
        LanguageOption(id: "de", name: "德语", chineseName: "德语"),
        LanguageOption(id: "es", name: "西班牙语", chineseName: "西班牙语"),
        LanguageOption(id: "pt", name: "葡萄牙语", chineseName: "葡萄牙语"),
        LanguageOption(id: "ru", name: "俄语", chineseName: "俄语"),
        LanguageOption(id: "ar", name: "阿拉伯语", chineseName: "阿拉伯语"),
        LanguageOption(id: "tr", name: "土耳其语", chineseName: "土耳其语"),
        LanguageOption(id: "th", name: "泰语", chineseName: "泰语"),
        LanguageOption(id: "vi", name: "越南语", chineseName: "越南语"),
        LanguageOption(id: "pl", name: "波兰语", chineseName: "波兰语"),
        LanguageOption(id: "nl", name: "荷兰语", chineseName: "荷兰语"),
    ]

    static let sourceLanguages: [LanguageOption] = [auto] + allLanguages

    static func named(_ id: String) -> LanguageOption? {
        allLanguages.first { $0.id == id }
    }

    /// 语言代码 → OCR 语言（Apple Vision）
    var ocrLanguages: [String] {
        switch id {
        case "ja": return ["ja", "en-US"]
        case "ko": return ["ko", "en-US"]
        case "zh-Hans": return ["zh-Hans", "en-US"]
        case "zh-Hant": return ["zh-Hant", "en-US"]
        case "zh-HK": return ["zh-Hant", "zh-Hans", "en-US"]
        case "en": return ["en-US"]
        case "auto": return ["en-US", "ja", "ko", "zh-Hans", "zh-Hant", "it", "fr", "de", "es"]
        default: return [id, "en-US"]
        }
    }
}

// MARK: - 应用设置（持久化）

final class AppSettings: ObservableObject {
    @Published var apiEndpoint: String {
        didSet { UserDefaults.standard.set(apiEndpoint, forKey: "apiEndpoint") }
    }

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "apiKey") }
    }

    @Published var modelID: String {
        didSet { UserDefaults.standard.set(modelID, forKey: "modelID") }
    }

    @Published var apiFormat: APIFormat {
        didSet { UserDefaults.standard.set(apiFormat.rawValue, forKey: "apiFormat") }
    }

    @Published var sourceLang: String {
        didSet { UserDefaults.standard.set(sourceLang, forKey: "sourceLang") }
    }

    @Published var targetLang: String {
        didSet { UserDefaults.standard.set(targetLang, forKey: "targetLang") }
    }

    @Published var taskConcurrency: Int {
        didSet { UserDefaults.standard.set(taskConcurrency, forKey: "taskConcurrency") }
    }

    @Published var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: "temperature") }
    }

    @Published var outputFormat: OutputFormat {
        didSet { UserDefaults.standard.set(outputFormat.rawValue, forKey: "outputFormat") }
    }

    @Published var customPromptTemplate: String {
        didSet {
            if customPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.removeObject(forKey: "customPromptTemplate")
                if !customPromptTemplate.isEmpty {
                    customPromptTemplate = ""
                }
            } else {
                UserDefaults.standard.set(customPromptTemplate, forKey: "customPromptTemplate")
            }
        }
    }

    @Published var domain: TranslationDomain {
        didSet { UserDefaults.standard.set(domain.rawValue, forKey: "domain") }
    }

    @Published var customDomainPrompt: String {
        didSet { UserDefaults.standard.set(customDomainPrompt, forKey: "customDomainPrompt") }
    }

    @Published var subtitleFormat: SubtitleFormat {
        didSet { UserDefaults.standard.set(subtitleFormat.rawValue, forKey: "subtitleFormat") }
    }

    @Published var subtitleBilingual: Bool {
        didSet { UserDefaults.standard.set(subtitleBilingual, forKey: "subtitleBilingual") }
    }

    // MARK: 跨页分批批量翻译
    @Published var batchTranslationEnabled: Bool {
        didSet { UserDefaults.standard.set(batchTranslationEnabled, forKey: "batchTranslationEnabled") }
    }

    @Published var batchPagesLimit: Int {
        didSet { UserDefaults.standard.set(batchPagesLimit, forKey: "batchPagesLimit") }
    }

    @Published var batchConcurrency: Int {
        didSet { UserDefaults.standard.set(batchConcurrency, forKey: "batchConcurrency") }
    }

    init() {
        let d = UserDefaults.standard
        self.apiEndpoint = d.string(forKey: "apiEndpoint") ?? "http://localhost:11434"
        self.apiKey = d.string(forKey: "apiKey") ?? ""
        self.modelID = d.string(forKey: "modelID") ?? "demonbyron/HY-MT1.5-1.8B:latest"
        let fmt = d.string(forKey: "apiFormat") ?? APIFormat.ollama.rawValue
        self.apiFormat = APIFormat(rawValue: fmt) ?? .ollama
        self.sourceLang = d.string(forKey: "sourceLang") ?? "it"
        self.targetLang = d.string(forKey: "targetLang") ?? "zh-Hans"
        let tc = d.integer(forKey: "taskConcurrency")
        self.taskConcurrency = tc < 1 ? 1 : min(tc, 16)
        let t = d.double(forKey: "temperature")
        self.temperature = t == 0 ? 0.7 : t
        let out = d.string(forKey: "outputFormat") ?? OutputFormat.sameAsInput.rawValue
        self.outputFormat = OutputFormat(rawValue: out) ?? .sameAsInput
        self.customPromptTemplate = d.string(forKey: "customPromptTemplate") ?? ""
        let dom = d.string(forKey: "domain") ?? TranslationDomain.general.rawValue
        self.domain = TranslationDomain(rawValue: dom) ?? .general
        self.customDomainPrompt = d.string(forKey: "customDomainPrompt") ?? ""

        let sub = d.string(forKey: "subtitleFormat") ?? SubtitleFormat.srt.rawValue
        self.subtitleFormat = SubtitleFormat(rawValue: sub) ?? .srt
        self.subtitleBilingual = d.object(forKey: "subtitleBilingual") == nil ? true : d.bool(forKey: "subtitleBilingual")

        // 跨页批量翻译现在是图片翻译的固定流程；保留字段仅用于兼容旧数据结构。
        self.batchTranslationEnabled = true
        let bpl = d.integer(forKey: "batchPagesLimit")
        self.batchPagesLimit = (1...8).contains(bpl) ? bpl : 8
        // 兼容旧版本的“并发数”：如果新设置不存在，就把旧值迁移为翻译并发。
        let bc = d.object(forKey: "batchConcurrency") == nil
            ? d.integer(forKey: "concurrency")
            : d.integer(forKey: "batchConcurrency")
        self.batchConcurrency = bc < 1 ? 1 : min(bc, 16)
    }
}

// MARK: - 翻译领域（定向优化）

enum TranslationDomain: String, CaseIterable, Identifiable {
    case general = "general"
    case comic = "comic"
    case novel = "novel"
    case academic = "academic"
    case finance = "finance"
    case tech = "tech"
    case medical = "medical"
    case legal = "legal"
    case game = "game"
    case marketing = "marketing"
    case news = "news"
    case subtitle = "subtitle"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "通用"
        case .comic: return "漫画 / 动漫"
        case .novel: return "小说 / 文学"
        case .academic: return "学术论文"
        case .finance: return "财经 / 财报"
        case .tech: return "科技 / IT"
        case .medical: return "医学 / 生物"
        case .legal: return "法律 / 合同"
        case .game: return "游戏"
        case .marketing: return "营销 / 广告"
        case .news: return "新闻 / 时事"
        case .subtitle: return "影视字幕"
        case .custom: return "自定义领域"
        }
    }

    var icon: String {
        switch self {
        case .general: return "globe"
        case .comic: return "book.pages"
        case .novel: return "book"
        case .academic: return "graduationcap"
        case .finance: return "chart.line.uptrend.xyaxis"
        case .tech: return "cpu"
        case .medical: return "cross.case"
        case .legal: return "scalemass"
        case .game: return "gamecontroller"
        case .marketing: return "megaphone"
        case .news: return "newspaper"
        case .subtitle: return "captions.bubble"
        case .custom: return "slider.horizontal.3"
        }
    }

    var shortDescription: String {
        switch self {
        case .general: return "默认通用翻译，无特殊领域倾向"
        case .comic: return "保留口语、拟声词、角色语气；不翻译人名、作品名"
        case .novel: return "保留文学性和意境，注重叙事流畅"
        case .academic: return "保留学术术语缩写（如 LLM、RAG、CNN），使用严谨书面语"
        case .finance: return "财经术语优先（如 MVP=最低可行产品→最有价值供应商；EPS、ROI、EBITDA 等）"
        case .tech: return "IT/编程术语保留原文（如 API、SDK、Pod、Kubernetes），代码/变量不译"
        case .medical: return "医学术语准确（如 MRI、CT、BMI），保留拉丁文学名"
        case .legal: return "严格忠实原文，法律术语精确（如 IP=知识产权、NDA、LLC）"
        case .game: return "游戏术语和玩家习惯用语（如 MVP=最有价值玩家，DPS、Boss、NPC）"
        case .marketing: return "语言活泼有感染力，保留品牌名和标语原文"
        case .news: return "客观简洁，保留机构名、人名原文"
        case .subtitle: return "简短口语化，保持节奏感，单行尽量短"
        case .custom: return "使用下方自定义提示词"
        }
    }

    /// 注入到翻译 prompt 中的领域指令
    func systemInstruction(customPrompt: String = "") -> String {
        switch self {
        case .general:
            return ""
        case .comic:
            return """
            这是漫画/动漫对话翻译。要求：
            - 保持口语化、贴近角色语气（少年、少女、老人等）
            - 拟声词（如「ゴゴゴ」「ズキーン」）保留语感或用中文拟声词对应
            - 人名、作品名、招式名如已有常见译名则使用，否则保留原文
            - 感叹词和省略号保留原有表达力
            - 避免使用书面语和复杂长句
            """
        case .novel:
            return """
            这是文学/小说翻译。要求：
            - 保留原文的文学性、意境和节奏
            - 对话自然流畅，叙述部分保持作者风格
            - 修辞手法（比喻、排比等）尽量保留
            - 避免机械直译
            """
        case .academic:
            return """
            这是学术论文翻译。要求：
            - 使用规范、严谨的学术书面语
            - 学术缩写保留原文（如 LLM、RAG、CNN、Transformer、SGD、FLOPs 等）
            - 专有名词首次出现可在中文译名后附英文原文
            - 数学公式、变量名、算法名保留原文
            - 被动句可根据中文习惯改为主动句
            """
        case .finance:
            return """
            这是财经/财报翻译。要求：
            - 金融术语使用行业标准译法：
              * EPS=每股收益，ROI=投资回报率，ROE=净资产收益率
              * EBITDA=息税折旧摊销前利润，GAAP=公认会计准则
              * Q1/Q2/Q3/Q4 保留原文（第一/二/三/四季度）
              * YoY=同比，QoQ=环比，MoM=环比（月）
            - "MVP" 在财经语境指"最有价值供应商/合作伙伴"而非"最小可行产品"
            - 货币单位、数字精确保留
            - 使用客观、严谨的陈述语气
            """
        case .tech:
            return """
            这是科技/IT 文档翻译。要求：
            - 技术术语和缩写保留英文原文：
              * API、SDK、CLI、GUI、CI/CD、K8s、Pod、Docker
              * HTTP/HTTPS、TCP/UDP、SSL/TLS、JSON、YAML
              * repository、commit、pull request、merge
            - "MVP" 在科技语境指"最小可行产品（Minimum Viable Product）"
            - 代码片段、变量名、函数名、文件路径一律保留原文
            - 命令、URL、路径、邮箱不翻译
            - 语气简洁、技术化
            """
        case .medical:
            return """
            这是医学/生物翻译。要求：
            - 医学术语使用标准译名，缩写保留原文：
              * MRI、CT、PET、ECG、EEG、BMI、BP、HR
              * DNA、RNA、mRNA、PCR、CRISPR
              * FDA、WHO、NIH 保留原文
            - 药物名、疾病名、解剖学名称使用规范译法
            - 拉丁文学名（如物种名、分类）保留原文斜体概念
            - 语气严谨、客观
            """
        case .legal:
            return """
            这是法律/合同翻译。要求：
            - 严格忠实原文，不增减信息
            - 法律术语精确使用标准译名：
              * IP=知识产权、NDA=保密协议、LLC=有限责任公司
              * T&C=条款与条件、SLA=服务等级协议
              * Plaintiff=原告、Defendant=被告、Jurisdiction=管辖权
            - 日期、金额、方名、条款编号精确保留
            - 使用正式法律书面语
            """
        case .game:
            return """
            这是游戏文本翻译。要求：
            - 游戏术语使用玩家习惯表达：
              * MVP=最有价值玩家、DPS=每秒伤害、HP=血量、MP=魔法
              * Boss=首领/Boss、NPC=非玩家角色、PvP/PvE 保留原文
              * 副本、技能、装备、Buff/Debuff 使用玩家熟悉说法
            - 角色名、招式名、地名可音译或沿用官方译名
            - 保持趣味性和游戏感，避免过于严肃的书面语
            """
        case .marketing:
            return """
            这是营销/广告文案翻译。要求：
            - 语言有感染力、简洁有力
            - 品牌名、产品名、标语保留英文原文
            - "MVP" 在营销语境可指"最有价值产品/客户"
            - 号召性语句（CTA）译文要有冲击力
            - 必要时可意译以保留广告效果
            """
        case .news:
            return """
            这是新闻/时事翻译。要求：
            - 客观中立，不带个人观点
            - 机构名、人名、地名保留原文或使用通用中文译名
            - 引语（Quote）准确翻译，保留原语气
            - 日期、数字、职位精确
            - 使用新闻体的简洁书面语
            """
        case .subtitle:
            return """
            这是影视字幕翻译。要求：
            - 简短口语化，适合观众快速阅读
            - 单行尽量不超过 15 个汉字
            - 保留说话人语气（急促、慵懒、严肃等）
            - 常见表达贴近中文口语（如 "yeah" → "是啊"而非"是的"）
            - 省略非必要内容（如反复的"well"、"you know"）
            """
        case .custom:
            return customPrompt.isEmpty ? "" : customPrompt
        }
    }
}

// MARK: - API 格式

enum APIFormat: String, CaseIterable, Identifiable {
    case ollama = "ollama"
    case openaiCompatible = "openai"
    case hyMT = "hy-mt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama（通用本地模型）"
        case .openaiCompatible: return "OpenAI 兼容"
        case .hyMT: return "HY-MT（腾讯混元翻译）"
        }
    }

    var defaultEndpoint: String {
        switch self {
        case .ollama, .hyMT: return "http://localhost:11434"
        case .openaiCompatible: return "https://api.openai.com/v1"
        }
    }
}

// MARK: - 输出格式

enum OutputFormat: String, CaseIterable, Identifiable {
    case sameAsInput = "same"
    case zip = "zip"
    case cbz = "cbz"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sameAsInput: return "与输入相同"
        case .zip: return "ZIP"
        case .cbz: return "CBZ（漫画）"
        }
    }
}

// MARK: - 字幕输出格式（音视频专用）

enum SubtitleFormat: String, CaseIterable, Identifiable {
    case srt
    case txt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .srt: return "SRT（字幕）"
        case .txt: return "TXT（纯文本）"
        }
    }

    var fileExtension: String { rawValue }
}
