import test from 'node:test'
import assert from 'node:assert/strict'

import {
  apply,
  get,
  inject,
  isSkillName,
  list,
  name,
  parseFrontmatter,
} from '../index.js'

test('parseFrontmatter 去 BOM/CRLF、跳过缩进 metadata 子键', () => {
  const src = '\uFEFF---\r\nname: demo-skill\r\ndescription: "a demo"\r\nmetadata:\r\n  min: 1\r\n---\r\n# body\r\n'
  const { fm, body } = parseFrontmatter(src)
  assert.equal(fm.name, 'demo-skill')
  assert.equal(fm.description, 'a demo')
  assert.equal(fm.metadata, '')
  assert.equal(body, '# body\n')
})

test('parseFrontmatter 对没有 frontmatter 的文本原样返回正文', () => {
  const src = '# just markdown\n'
  const { fm, body } = parseFrontmatter(src)
  assert.deepEqual(fm, {})
  assert.equal(body, src)
})

test('isSkillName 只接受 DSH 的 kebab-case', () => {
  assert.equal(isSkillName('github-release-download-acceleration'), true)
  assert.equal(isSkillName('a1-b2'), true)
  assert.equal(isSkillName('UPPER'), false)
  assert.equal(isSkillName('-leading'), false)
  assert.equal(isSkillName('two--dash'), false)
  assert.equal(isSkillName(''), false)
})

test('list() 从包内 SKILL.md 读出一条 bundled 候选', async () => {
  const candidates = await list()
  assert.equal(candidates.length, 1)
  const c = candidates[0]
  assert.equal(c.name, name)
  assert.equal(c.provider, name)
  assert.equal(c.source, 'bundled')
  assert.equal(c.rank, 600)
  assert.equal(c.resourceBase.kind, 'directory')
  assert.ok(c.resourceBase.path)
  assert.ok(c.path.endsWith('SKILL.md'))
  assert.ok(c.description.length >= 40)
  assert.deepEqual(c.invocation, { modelInvocable: true, userInvocable: true })
})

test('get() 返回剥离 frontmatter 的正文，并与候选同名', async () => {
  const [candidate] = await list()
  const skill = await get(candidate)
  assert.equal(skill.name, candidate.name)
  assert.equal(skill.description, candidate.description)
  assert.equal(skill.path, candidate.path)
  assert.match(skill.content, /^## Steps/m)
  assert.match(skill.content, /## Pitfalls/)
  assert.doesNotMatch(skill.content, /^---$/m)
})

test('apply() 把无状态 provider 注册进 ctx.skills', () => {
  let registered
  apply({ skills: { registerProvider(fn) { registered = fn } } })
  assert.equal(typeof registered, 'function')
  assert.equal(registered().name, name)
  assert.deepEqual(inject, ['skills'])
})
