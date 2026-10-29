/**
 * github-release-download-acceleration — DSH 技能提供者：把本包自带的 SKILL.md 挂进 `ctx.skills`。
 *
 * 为什么需要这一层：插件市场只收「能用 `dsh plugin add` 装上的包」，包必须声明
 * `dsh.bundle` 并在根放一份 cordis.patch.yml；而技能正文只是一份 SKILL.md，
 * 要有 provider 才会进会话的技能目录。本文件就是那层很薄的接线。
 *
 * 三条刻意的性质：
 *   · **不复制技能正文** —— 候选与正文都在调用时从 SKILL.md 现读，改正文不必动本文件，
 *     也不会出现「描述与正文两份、各自漂移」。
 *   · **零依赖** —— 只用 `node:` 内置模块。技能本体是一份纯 PowerShell 文档，
 *     不需要任何 JS 运行时依赖。
 *   · **不缓存** —— 没有音视频/大文件，读一次 SKILL.md 只有几十 KB，现读最省事也最不容易错。
 *
 * @module github-release-download-acceleration
 */

import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

/** 包根（本文件所在目录）。SKILL.md、agents/、scripts/ 都在那里。 */
const ROOT_URL = new URL('.', import.meta.url)
const SKILL_URL = new URL('SKILL.md', ROOT_URL)
/** SKILL.md 的绝对路径：候选与定义的 `path` 都用它。 */
const SKILL_PATH = fileURLToPath(SKILL_URL)
/** 包根绝对路径，去掉末尾分隔符：宿主会自己做 Join，带 `\` 结尾容易拼出双分隔符。 */
const ROOT_PATH = fileURLToPath(ROOT_URL).replace(/[\\/]+$/, '')

/** provider 名，在 `ctx.skills` 注册表里唯一。 */
/**
 * Cordis 插件名（必须等于 cordis.patch.yml 的 `id`）。
 *
 * 写成字面量而不是只留一个间接常量：`scripts/validate.ps1` 与市场 CI 都会静态读这一行，
 * 拿它去和 patch 的 `id`、package.json 的 `name` 比对。
 */
export const name = 'github-release-download-acceleration'
const PROVIDER_NAME = name

/**
 * bundled 档的秩。DSH 里 `BUNDLED_SKILL_RANK = 600`（project 100/200、custom 300、
 * user-dsh 400、user-agents 500）。秩只在**同名技能**上起作用，且低秩胜出：用户若在
 * `~/.dsh/skills/` 放了本地特化版，仍然优先于本插件。
 */
const RANK = 600

/**
 * 读 SKILL.md 的 YAML frontmatter。只认本技能用到的几个键，因此不需要 YAML 依赖：
 * `name` / `description` / `disable-model-invocation` / `user-invocable`。
 *
 * 缩进行（本技能的 `metadata:` 子键）不匹配 `^key:`，会被自然跳过 —— 这是刻意的：
 * 插件的包装层不关心阈值，阈值由技能自己的 validate.ps1 与正文代码保证一致。
 *
 * @param {string} text - SKILL.md 全文。
 * @returns {{fm: Record<string, string>, body: string}} frontmatter 键值表与去掉它的正文。
 */
export function parseFrontmatter(text) {
  // 去 BOM、归一 CRLF：编辑器编码与 Windows 检出不该改变解析结果。
  const src = text.replace(/^\uFEFF/, '').replace(/\r\n/g, '\n')
  if (!src.startsWith('---')) return { fm: {}, body: text }
  const end = src.indexOf('\n---', 3)
  if (end === -1) return { fm: {}, body: text }
  const fm = {}
  for (const line of src.slice(3, end).split('\n')) {
    const m = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/)
    if (m) fm[m[1]] = m[2].trim().replace(/^["']|["']$/g, '')
  }
  return { fm, body: src.slice(end + 4).trimStart() }
}

/** 技能名必须匹配 DSH 的 kebab-case 语法，否则注册表会拒收这个候选。 */
export function isSkillName(name) {
  return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(String(name))
}

/** frontmatter 的调用开关：省略即两处都开。 */
function invocationOf(fm) {
  return {
    modelInvocable: String(fm['disable-model-invocation'] ?? '').toLowerCase() !== 'true',
    userInvocable: String(fm['user-invocable'] ?? '').toLowerCase() !== 'false',
  }
}

/**
 * 读候选。读失败**不吞**：让 `list()` 拒绝比返回空数组诚实 —— 注册表会把拒绝记成一次
 * 不完整观测并保留上一次的好目录，而返回空数组等于告诉模型「这个技能被删了」。
 *
 * @returns {Promise<object[]>} 本包只提供一条技能。
 */
export async function list() {
  const { fm } = parseFrontmatter(await readFile(SKILL_URL, 'utf8'))
  if (!isSkillName(fm.name)) {
    throw new Error(`SKILL.md 的 frontmatter name 不是 kebab-case：${JSON.stringify(fm.name)}`)
  }
  if (!fm.description) throw new Error('SKILL.md 的 frontmatter 缺少 description')
  return [
    {
      name: fm.name,
      description: fm.description,
      invocation: invocationOf(fm),
      provider: PROVIDER_NAME,
      source: 'bundled',
      // 资源基准指向包根：正文里写的 `scripts\validate.ps1`、`agents\openai.yaml` 因此可解析。
      resourceBase: { kind: 'directory', path: ROOT_PATH },
      rank: RANK,
      // 给宿主/子代理一个能直接打开的技能文件位置。
      path: SKILL_PATH,
      locator: SKILL_URL,
    },
  ]
}

/**
 * 读正文：frontmatter 已剥离，返回的就是指令正文。
 *
 * @param {object} candidate - `list()` 给出的候选。
 * @returns {Promise<object>} 完整技能定义。
 */
export async function get(candidate) {
  const { fm, body } = parseFrontmatter(await readFile(SKILL_URL, 'utf8'))
  // 正文的 name 与候选不一致说明两次读之间文件被换过：抛出去让注册表重新发现，
  // 而不是交出一份名不副实的定义。
  if (fm.name !== candidate.name) {
    throw new Error(`SKILL.md 的 name 已变为 ${JSON.stringify(fm.name)}，与候选 ${JSON.stringify(candidate.name)} 不符`)
  }
  return {
    name: candidate.name,
    description: fm.description || candidate.description,
    invocation: candidate.invocation,
    provider: PROVIDER_NAME,
    source: 'bundled',
    resourceBase: candidate.resourceBase,
    path: SKILL_PATH,
    content: body,
  }
}

/** 本 provider 的实例（无内部状态：不缓存正文，全部现读）。 */
export const provider = { name: PROVIDER_NAME, list, get }

/** 本插件依赖的服务：技能注册表。 */
export const inject = ['skills']

/**
 * 挂载：把本 provider 注册到 `ctx.skills`。注册是同步的，发现与读正文都在 awaits 里。
 *
 * @param {{skills: {registerProvider: Function}}} ctx - Cordis 上下文。
 * @returns {void}
 */
export function apply(ctx) {
  ctx.skills.registerProvider(() => provider)
}
