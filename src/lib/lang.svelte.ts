// The desk's language, as ReDesk's Settings › Language says (English or Japanese): the side buttons are
// written in it. ReDesk keeps it (read at start, `desk_language`) and says when it changes (a `language`
// event from src-tauri's listen_for_desk_language). A word not here stays in English.
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';

const japanese: Record<string, string> = {
	// four characters each, as the English words are four letters
	COLM: '縦列表示',
	LIST: '一覧表示',
	INFO: '詳細情報',
	DEL: '削除する',
	SONG: '楽曲一覧',
	LIVE: 'ラジオ局',
	MINI: 'ミニ表示',
	PREV: '前の曲へ',
	NEXT: '次の曲へ',
	READ: '中を見る',
	ADD: '追加する',
	EDIT: '編集する',
	NOVA: '新規作成',
	CLOSE: '閲覧終了',
	BACK: '前に戻る',
	FULL: '全画面化',
	MANGA: '右から左',
	FAVO: '栞を挟む',
	PEN: 'ペン書き',
	BRUSH: '筆で書く',
	UNDO: '元に戻す',
	PAD: '指で描く',
	SAVE: '保存する',
	RUB: '消しゴム',
	EXIT: '編集終了',
	IMP: '読み込み',
	EXP: '書き出し',
	HOME: 'ホームへ',
	'NEW TAB': '新規タブ',
	'FULL NOTE': '全文表示',
	'NEXT SPACE': '次の場所',
};

// the popups' words: headings, texts, their buttons, the keys they list
const japaneseText: Record<string, string> = {
	'Move “{name}” to Trash?': '「{name}」をゴミ箱に入れますか？',
	'YES': 'はい',
	'NO': 'いいえ',
	'NEW TEXT': '新しいテキスト',
	'NEW FOLDER': '新しいフォルダ',
	'CREATE': '作成',
	'CANCEL': 'キャンセル',
	'RENAME': '名前を変更',
	'Open': '開く',
	'Rename': '名前を変更',
	'Duplicate': '複製',
	'Compress': '圧縮',
	'Copy path': 'パスをコピー',
	'Show in Finder': 'Finderで表示',
	'Info': '情報',
	'Move to Trash': 'ゴミ箱に入れる',
	'Kind': '種類',
	'Items': '項目数',
	'Size': 'サイズ',
	'Created': '作成日',
	'Modified': '変更日',
	'Where': '場所',
	'local · private · offline': 'ローカル · 非公開 · オフライン',
	'This folder in FILE / TEXT / VIEW / PLAY': 'このフォルダを FILE / TEXT / VIEW / PLAY で',
	'The folder selected, all inside it (at any depth), in a new window': '選んだフォルダの中身をすべて（どの深さも）新しいウィンドウで',
	'New window': '新しいウィンドウ',
	'Select': '選ぶ',
	'Open (a file: in a new window, in its mode)': '開く（ファイルは新しいウィンドウで、その種類のモードで）',
	'A quick look at a picture or text, here': '画像やテキストをここでちらっと見る',
	'Save the text (it saves itself too)': 'テキストを保存（自動でも保存されます）',
	'Back': '戻る',
	'Search': '検索',
	'Columns / List': '列 / 一覧',
	'Sort by name / kind / date / size (again: the other way)': '名前 / 種類 / 日付 / サイズで並べる（もう一度で逆順）',
	'New folder': '新しいフォルダ',
	'Actions': '操作',
	'E / right click': 'E / 右クリック',
	'Space': 'スペース',
	'Play': '再生',
	'Play next': '次に再生',
	'Add to queue': '再生待ちに追加',
	'UP NEXT': '次に再生',
	'Nothing after this song.': 'この曲の後には何もありません。',
	'{n} song': '{n}曲',
	'{n} songs': '{n}曲',
	'No folder chosen': 'フォルダが選ばれていません',
	'FOLDER': 'フォルダ',
	'RESCAN': '再スキャン',
	'Folder / songs / radio': 'フォルダ / 曲 / ラジオ',
	'Play / pause': '再生 / 一時停止',
	"Previous / next song (the Mac's media keys)": '前 / 次の曲（Macのメディアキー）',
	'Play (a video: here)': '再生（動画はここで）',
	'Genres / stations (radio)': 'ジャンル / 局（ラジオ）',
	'Keep a station': '局を保存',
	'Shuffle / repeat': 'シャッフル / リピート',
	'Up next': '次に再生',
	'Mini player': 'ミニプレーヤー',
};

export const language = $state({ japanese: false });

// The language turning, as on a departures board: each letter runs through others (Latin and katakana)
// before it stops at its new one, the first soonest, the next a little later (as ReDesk's corner words).
const POOL = [...'アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'];
const STEP = 55, SETTLE = 260, STAGGER = 110, LENGTH = 1200;
const flap = $state({ frame: -1 });

/** a button's word in the desk's language; `as` names it where the same word means another thing (NEW TAB) */
export function t(word: string, as?: string): string {
	const target = language.japanese ? (japanese[as ?? word] ?? word) : word;
	const frame = flap.frame;
	if (frame < 0) return target;
	const elapsed = frame * STEP;
	return [...target]
		.map((letter, i) => {
			if (letter === ' ' || elapsed >= SETTLE + i * STAGGER) return letter;
			let hash = frame * 31 + i * 17;
			for (const c of as ?? word) hash = (hash * 33 + c.charCodeAt(0)) | 0;
			return POOL[Math.abs(hash) % POOL.length];
		})
		.join('');
}

/** the popups' words (any length) in the desk's language; {name} in them is filled from `values` */
export function tx(text: string, values?: Record<string, string | number>): string {
	let out = language.japanese ? (japaneseText[text] ?? text) : text;
	if (values) for (const [key, value] of Object.entries(values)) out = out.replaceAll(`{${key}}`, String(value));
	return out;
}

let flapTimer: ReturnType<typeof setInterval> | null = null;
function turn() {
	if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
	if (flapTimer) clearInterval(flapTimer);
	flap.frame = 0;
	flapTimer = setInterval(() => {
		if ((flap.frame + 1) * STEP > LENGTH) {
			flap.frame = -1;
			clearInterval(flapTimer!);
			flapTimer = null;
		} else flap.frame++;
		repaint();
	}, STEP);
}

// WebKit leaves upright vertical words in a see-through window as they were painted, though their text has
// changed: each frame (and the last, after the words have settled) the buttons are told to paint again
// (app.css: html[data-flap] changes nothing to look at)
function repaint() {
	const root = document.documentElement;
	root.dataset.flap = root.dataset.flap === '1' ? '0' : '1';
	if (flap.frame < 0) requestAnimationFrame(() => requestAnimationFrame(() => delete root.dataset.flap));
}

function set(code: string, animate = false) {
	const japanese = code === 'ja';
	if (animate && japanese !== language.japanese) turn();
	language.japanese = japanese;
	document.documentElement.lang = language.japanese ? 'ja' : 'en';
}

/** once, at start: the language ReDesk keeps, and its word when it changes */
export function followDeskLanguage() {
	if (!('__TAURI_INTERNALS__' in window)) return;
	invoke<string>('desk_language').then(set).catch(() => {});
	listen<string>('language', e => set(e.payload, true));
}
