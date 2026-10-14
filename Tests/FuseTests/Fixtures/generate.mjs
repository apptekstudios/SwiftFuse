import Fuse from 'fuse.js'
import { writeFileSync } from 'node:fs'

const books = [
  { title: "Old Man's War", author: 'John Scalzi', tags: ['fiction', 'sci-fi'] },
  { title: 'The Lock Artist', author: 'Steve Hamilton', tags: ['thriller'] },
  { title: 'HTML5', author: 'Remy Sharp', tags: ['web', 'html', 'programming'] },
  { title: 'Right Ho Jeeves', author: 'P.D. Woodhouse', tags: [] },
  { title: 'The Code of the Wooster', author: 'P.D. Woodhouse', tags: ['comedy', 'jeeves'] },
  { title: 'Thank You Jeeves', author: 'P.D. Woodhouse' },
  { title: 'The DaVinci Code', author: 'Dan Brown', tags: ['thriller', 'code'] },
  { title: 'Angels & Demons', author: 'Dan Brown', tags: ['thriller'] },
  { title: 'The Silmarillion', author: 'J.R.R. Tolkien', tags: ['fantasy'] },
  { title: 'Syrup', author: 'Max Barry', tags: ['satire'] },
  { title: 'The Lost Symbol', author: 'Dan Brown', tags: ['thriller', 'symbol'] },
  { title: 'The Book of Lies', author: 'Brad Meltzer', tags: ['thriller', 'lies'] },
  { title: 'Lamb', author: 'Christopher Moore', tags: ['comedy', 'religion'] },
  { title: 'Fool', author: 'Christopher Moore', tags: ['comedy'] },
  { title: 'Incompetence', author: 'Rob Grant', tags: ['comedy', 'sci-fi'] },
  { title: 'Fat', author: 'Rob Grant', tags: ['comedy'] },
  { title: 'Colony', author: 'Rob Grant', tags: ['sci-fi'] },
  { title: 'Backwards, Red Dwarf', author: 'Rob Grant', tags: ['sci-fi', 'comedy'] },
  { title: 'The Grand Design', author: 'Stephen Hawking', tags: ['science', 'physics'] },
  { title: 'The Book of Samson', author: 'David Maine', tags: ['religion'] },
  { title: 'The Preservationist', author: 'David Maine' },
  { title: 'Fallen', author: 'David Maine', tags: ['  '] },
  { title: 'Monster 1959', author: 'David Maine', tags: ['horror', 'sci-fi'] },
  { title: '  ', author: 'Blank Title', tags: ['blank'] },
  { title: 'A very long title that goes on and on for well over thirty two characters to force chunking', author: 'Verbose Writer', tags: ['long'] },
]
const strings = ["Old Man's War", 'The Lock Artist', 'HTML5', 'Right Ho Jeeves', 'The Code of the Wooster', 'Thank You Jeeves', 'The DaVinci Code', 'Angels & Demons', 'The Silmarillion', 'Syrup', 'The Lost Symbol', 'The Book of Lies', 'Lamb', 'Fool', 'Incompetence', 'Fat', 'Colony', 'Backwards, Red Dwarf', 'The Grand Design', 'The Book of Samson', 'The Preservationist', 'Fallen', 'Monster 1959', '   ', 'hello world', 'Hello World', 'HELLO', 'helo wrld', 'A very long sentence that keeps going well past thirty two characters so that it needs chunking']
const unicode = ['Crème Brûlée', 'creme brulee', 'Café Noir', 'cafe noir', 'naïve', 'naive', 'Zoë Saldaña', 'Łódź', 'lodz', 'Ørsted', 'orsted', 'Ħal Qormi', 'résumé', 'resume', 'Ελληνικά', 'Привет мир', '日本語テキスト', '🍎 apple pie', 'apple 🥧 pie', 'éclair']
const names = ['John Smith', 'Jane Doe', 'Bob Wilson', 'Alice Johnson', 'Johnny Appleseed', 'John Doe', 'Jonathan Swift', 'prefix_john', 'john_suffix', 'mid_john_dle', 'test at start', 'this is a test string', 'end test', 'no match here']
const bookKeys = [{ name: 'title', weight: 2 }, { name: 'author', weight: 1 }, { name: 'tags', weight: 0.5 }]
const equalKeys = [{ name: 'title' }, { name: 'author' }, { name: 'tags' }]

function toFuseQuery(q, root = false) {
  if (root && typeof q !== 'string' && !q.and && !q.or) return { $and: [toFuseQuery(q)] }
  if (typeof q === 'string') return q
  if (q.and) return { $and: q.and.map(toFuseQuery) }
  if (q.or) return { $or: q.or.map(toFuseQuery) }
  return { $path: q.key, $val: q.pattern }
}

const cases = []
function add(name, { options = {}, keys = null, collection, query, limit = null }) {
  const fuseOptions = { ...options, includeScore: true }
  if (keys) fuseOptions.keys = keys
  const fuse = new Fuse(collection, fuseOptions)
  const results = fuse.search(toFuseQuery(query, true), limit === null ? undefined : { limit })
  const expected = results.map(r => ({
    refIndex: r.refIndex,
    score: r.score === undefined ? null : r.score,
    matches: (r.matches || []).map(m => ({ key: m.key ?? null, refIndex: m.refIndex ?? null, value: m.value, indices: m.indices })),
  }))
  cases.push({ name, options, keys, collection, query, limit, expected })
}

// --- plain strings, default options
for (const q of ['old', 'war', 'hllo', 'HELLO', 'jeeves', 'code', 'nonexist', 'the', 'xyzxyzxyz', 'o', 'The Lock Artist']) add(`strings default "${q}"`, { collection: strings, query: q })
add('strings blank pattern', { collection: strings, query: '   ' })
add('strings blank pattern limit', { collection: strings, query: '', limit: 3 })
add('strings includeMatches', { options: { includeMatches: true }, collection: strings, query: 'the' })
add('strings includeMatches hllo', { options: { includeMatches: true }, collection: strings, query: 'hllo wrld' })
add('strings threshold 0.2', { options: { threshold: 0.2 }, collection: strings, query: 'jeves' })
add('strings threshold 0', { options: { threshold: 0 }, collection: strings, query: 'Fool' })
add('strings threshold 1', { options: { threshold: 1 }, collection: strings, query: 'zq' })
add('strings ignoreLocation', { options: { ignoreLocation: true, includeMatches: true }, collection: strings, query: 'code' })
add('strings location 10', { options: { location: 10 }, collection: strings, query: 'code' })
add('strings distance 0', { options: { distance: 0 }, collection: strings, query: 'the' })
add('strings distance 0 loc 4', { options: { distance: 0, location: 4 }, collection: strings, query: 'code' })
add('strings distance 1000', { options: { distance: 1000 }, collection: strings, query: 'code' })
add('strings findAllMatches', { options: { findAllMatches: true, includeMatches: true }, collection: strings, query: 'e' })
add('strings minMatchCharLength 3', { options: { minMatchCharLength: 3, includeMatches: true }, collection: strings, query: 'the code' })
add('strings minMatchCharLength 4 no includeMatches', { options: { minMatchCharLength: 4 }, collection: strings, query: 'symbol' })
add('strings caseSensitive', { options: { isCaseSensitive: true }, collection: strings, query: 'Hello' })
add('strings caseSensitive upper', { options: { isCaseSensitive: true, includeMatches: true }, collection: strings, query: 'HELLO' })
add('strings shouldSort false', { options: { shouldSort: false }, collection: strings, query: 'the' })
add('strings limit 2', { collection: strings, query: 'the', limit: 2 })
add('strings limit 1 heap', { collection: strings, query: 'e', limit: 1 })
add('strings limit 0', { collection: strings, query: 'the', limit: 0 })
add('strings long pattern chunked', { options: { includeMatches: true }, collection: strings, query: 'a very long sentence that keeps going well past thirty two characters' })
add('strings long pattern chunked ignoreLocation', { options: { ignoreLocation: true, threshold: 0.4 }, collection: strings, query: 'sentence that keeps going well past thirty two characters so that it needs' })
add('strings exactly 32 chars', { options: { includeMatches: true }, collection: strings, query: 'a very long sentence that keeps ' })
add('names ignoreLocation 0.4', { options: { ignoreLocation: true, threshold: 0.4 }, collection: names, query: 'john' })
add('names default john', { options: { includeMatches: true }, collection: names, query: 'john' })
add('names test', { collection: names, query: 'test' })
add('names test ignoreLocation', { options: { ignoreLocation: true }, collection: names, query: 'test' })

// --- unicode
add('unicode creme', { options: { includeMatches: true }, collection: unicode, query: 'creme' })
add('unicode creme diacritics', { options: { ignoreDiacritics: true, includeMatches: true }, collection: unicode, query: 'creme brulee' })
add('unicode crème diacritics', { options: { ignoreDiacritics: true, includeMatches: true }, collection: unicode, query: 'Crème' })
add('unicode lodz diacritics', { options: { ignoreDiacritics: true, threshold: 0.3 }, collection: unicode, query: 'lodz' })
add('unicode orsted diacritics', { options: { ignoreDiacritics: true, threshold: 0.3 }, collection: unicode, query: 'orsted' })
add('unicode greek', { options: { includeMatches: true }, collection: unicode, query: 'ελλην' })
add('unicode cyrillic', { options: { includeMatches: true }, collection: unicode, query: 'мир' })
add('unicode japanese', { options: { includeMatches: true }, collection: unicode, query: '日本' })
add('unicode eclair', { options: { threshold: 0.3, includeMatches: true }, collection: unicode, query: 'eclair' })
add('unicode eclair diacritics', { options: { ignoreDiacritics: true, threshold: 0.3, includeMatches: true }, collection: unicode, query: 'eclair' })

// --- objects with keys
for (const q of ['old', 'woodhouse', 'brown', 'jeeves', 'thriller', 'comedy sci', 'code', 'nonexist', 'hawking', 'david', 'long']) {
  add(`books weighted "${q}"`, { keys: bookKeys, collection: books, query: q })
  add(`books equal "${q}"`, { keys: equalKeys, collection: books, query: q })
}
add('books weighted includeMatches', { options: { includeMatches: true }, keys: bookKeys, collection: books, query: 'thriller' })
add('books includeMatches comedy', { options: { includeMatches: true }, keys: equalKeys, collection: books, query: 'comedy' })
add('books ignoreFieldNorm', { options: { ignoreFieldNorm: true }, keys: bookKeys, collection: books, query: 'the' })
add('books fieldNormWeight 2', { options: { fieldNormWeight: 2 }, keys: bookKeys, collection: books, query: 'the' })
add('books fieldNormWeight 0', { options: { fieldNormWeight: 0 }, keys: bookKeys, collection: books, query: 'the' })
add('books fieldNormWeight 0.5', { options: { fieldNormWeight: 0.5 }, keys: equalKeys, collection: books, query: 'book' })
add('books single key', { keys: [{ name: 'author' }], collection: books, query: 'maine' })
add('books tags only', { keys: [{ name: 'tags', weight: 3 }], options: { includeMatches: true }, collection: books, query: 'sci' })
add('books shouldSort false limit 4', { options: { shouldSort: false }, keys: bookKeys, collection: books, query: 'the', limit: 4 })
add('books limit heap', { keys: bookKeys, collection: books, query: 'e', limit: 3 })
add('books ignoreLocation', { options: { ignoreLocation: true }, keys: bookKeys, collection: books, query: 'code' })
add('books threshold 0.3 includeMatches', { options: { threshold: 0.3, includeMatches: true }, keys: bookKeys, collection: books, query: 'wooster' })
add('books long chunked', { options: { includeMatches: true }, keys: bookKeys, collection: books, query: 'a very long title that goes on and on for well over thirty two' })
add('books blank query', { keys: bookKeys, collection: books, query: '' })

// --- extended search
const ext = { useExtendedSearch: true, includeMatches: true }
for (const q of ["=Fool", "='The Lock Artist'", '="The Lock Artist"', "'the", "'book", '^the', '!^the', 'code$', '!code$', '!the', 'jeeves | brown', 'the code', "'the 'code", '^the code$', 'woodhouse !jeeves', 'hwking', '"book of" lies', "'\"book of\"", '="Right Ho Jeeves"', '!^the !code$', 'the | =Fat', 'red \\| dwarf', 'symbl | artst', '^The \'Code', '!nonexist', '=Fat =Fool', '$', '=', "'", '!', '"unterminated quote', 'the "code of"$']) {
  add(`extended books "${q}"`, { options: ext, keys: bookKeys, collection: books, query: q })
  add(`extended strings "${q}"`, { options: ext, collection: strings, query: q })
}
add('extended no includeMatches', { options: { useExtendedSearch: true }, keys: bookKeys, collection: books, query: "'the !jeeves" })
add('extended caseSensitive', { options: { useExtendedSearch: true, isCaseSensitive: true }, collection: strings, query: "'Hello | =HELLO" })
add('extended diacritics', { options: { useExtendedSearch: true, ignoreDiacritics: true, includeMatches: true }, collection: unicode, query: "'creme | ^cafe" })
add('extended minMatchCharLength', { options: { useExtendedSearch: true, minMatchCharLength: 3, includeMatches: true }, collection: strings, query: "the cde" })

// --- logical queries
add('logical and keys', { keys: bookKeys, collection: books, query: { and: [{ key: 'author', pattern: 'brown' }, { key: 'title', pattern: 'code' }] } })
add('logical or keys', { keys: bookKeys, collection: books, query: { or: [{ key: 'author', pattern: 'hawking' }, { key: 'title', pattern: 'lamb' }] } })
add('logical nested', { options: { includeMatches: true }, keys: bookKeys, collection: books, query: { and: [{ key: 'tags', pattern: 'comedy' }, { or: [{ key: 'author', pattern: 'grant' }, { key: 'author', pattern: 'moore' }] }] } })
add('logical string leaf', { keys: bookKeys, collection: books, query: { and: ['jeeves', { key: 'title', pattern: 'thank' }] } })
add('logical or string leaves', { keys: bookKeys, collection: books, query: { or: ['hawking', 'tolkien'] } })
add('logical single key leaf', { keys: bookKeys, collection: books, query: { key: 'tags', pattern: 'thriller' } })
add('logical extended', { options: { useExtendedSearch: true }, keys: bookKeys, collection: books, query: { and: [{ key: 'author', pattern: '=Dan Brown' }, { key: 'title', pattern: "!code" }] } })
add('logical and empty', { keys: bookKeys, collection: books, query: { and: [] } })

// --- token search
const tok = { useTokenSearch: true }
for (const q of ['code', 'the code', 'book lies', 'dan brown thriller', 'jeves wodehouse', 'red dwarf backwards', 'nonexist', 'comedy', 'book of', 'man war scalzi']) {
  add(`token books "${q}"`, { options: tok, keys: bookKeys, collection: books, query: q })
  add(`token books all "${q}"`, { options: { ...tok, tokenMatch: 'all' }, keys: bookKeys, collection: books, query: q })
  add(`token strings "${q}"`, { options: { ...tok, includeMatches: true }, collection: strings, query: q })
}
add('token strings all includeMatches', { options: { useTokenSearch: true, tokenMatch: 'all', includeMatches: true }, collection: strings, query: 'the code' })
add('token threshold 0.2', { options: { useTokenSearch: true, threshold: 0.2 }, keys: bookKeys, collection: books, query: 'the code' })

writeFileSync(process.argv[2], JSON.stringify({ fuseVersion: Fuse.version, cases }, null, 0))
console.log(cases.length, 'cases')
