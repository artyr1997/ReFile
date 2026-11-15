<script lang="ts">
	import { onMount, tick, untrack } from 'svelte';
	import { invoke, convertFileSrc } from '@tauri-apps/api/core';
	import { getCurrentWindow } from '@tauri-apps/api/window';
	import WindowControls from './lib/WindowControls.svelte';
	import Popup from './lib/Popup.svelte';
	import { scrollFade } from './lib/scrollFade';
	import Play from './lib/play/Play.svelte';
	import Video from './lib/play/Video.svelte';
	import Reader from './lib/view/Reader.svelte';
	import { cachedCover } from './lib/view/formats';
	import { placeOf, type Book } from './lib/view/books';
	import type { Tab } from './lib/play/music';
	import { files, parentOf, nameOf, formatDate, formatSize, kindOf, imageType, bookFormat, modeOf, inMode, modes } from './lib/files';
	import type { Entry, Info, Mode } from './lib/files';

	type View = 'colm' | 'list';
	type PopupKind = 'none' | 'delete' | 'new' | 'info' | 'actions' | 'rename';
	type ActionId = 'open' | 'rename' | 'duplicate' | 'compress' | 'copy' | 'reveal' | 'info' | 'trash';

	// a window opened for a file (from FILE, or Open With in Finder: lib.rs, new_window): its mode, the file shown
	// or for every file inside a folder, at any depth (⇧Enter, ⇧F / T / V / P): `tree`
	const opened = (window as unknown as { __refileOpen?: { path: string | null; mode: Mode | null; tree?: string | null } }).__refileOpen;
	/** the folder whose every file is listed here, at any depth (an "all inside" window); null: just the folder's own */
	let flat: string | null = $state(null);
	// a window opened for a file or for all inside a folder keeps to it: its mode stays, and nothing
	// above its folder (the file's, or the one it shows all of) can be reached
	const locked = !!opened && !!(opened.path || opened.tree);
	let lockRoot = $state('');

	// ── the four modes: FILE everything, TEXT texts, VIEW pictures and books, PLAY music and videos ──
	function readSaved<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
		try {
			const saved = localStorage.getItem(key) as T | null;
			if (saved && allowed.includes(saved)) return saved;
		} catch {}
		return fallback;
	}
	let mode: Mode = $state(opened ? (opened.mode ?? 'file') : readSaved('mode', modes, 'file'));
	let playTab: Tab = $state(readSaved<Tab>('playTab', ['folder', 'songs', 'radio'], 'folder'));
	$effect(() => {
		try {
			localStorage.setItem('mode', mode);
			localStorage.setItem('playTab', playTab);
		} catch {}
	});
	/** F / T / V / P: this folder in that mode, the selection kept where it can be */
	function setMode(next: Mode) {
		if (next === mode || locked) return;
		const keep = current?.path;
		closeViewer();
		mode = next;
		query = '';
		const i = keep ? visible.findIndex(e => e.path === keep) : -1;
		selected = i >= 0 ? i : 0;
		scrollSelectedIntoView();
	}

	// a tiny window (the mini player's size, M): PLAY is the mini player there; a small one keeps its list
	let winWidth = $state(window.innerWidth);
	let winHeight = $state(window.innerHeight);
	let tiny = $derived(winWidth < 520 || winHeight < 420);
	let playPanel: ReturnType<typeof Play> | undefined = $state();
	// the browser shows, but in PLAY's songs and radio, and its mini player
	let browsing = $derived(mode !== 'play' || (playTab === 'folder' && !tiny));

	// VIEW: a book being read; PLAY: videos being shown
	let reading: Book | null = $state(null);
	let video: { paths: string[]; start: number } | null = $state(null);

	let view: View = $state('colm');
	let cwd = $state('');
	let entries: Entry[] = $state([]);
	let selected = $state(0);
	let query = $state('');
	let listError = $state('');

	let searchInput: HTMLInputElement | undefined = $state();
	let mainList: HTMLDivElement | undefined = $state();

	// right column in COLM view: contents of the selected folder, or details of the selected file
	let preview: Entry[] | null = $state(null);
	let previewInfo: Info | null = $state(null);
	let previewError = $state('');

	let popup: PopupKind = $state('none');
	let newName = $state('');
	let popupError = $state('');
	let info: Info | null = $state(null);
	let newNameInput: HTMLInputElement | undefined = $state();

	// actions menu (E or right click) and rename
	const actions: { id: ActionId; label: string }[] = [
		{ id: 'open', label: 'Open' },
		{ id: 'rename', label: 'Rename' },
		{ id: 'duplicate', label: 'Duplicate' },
		{ id: 'compress', label: 'Compress' },
		{ id: 'copy', label: 'Copy path' },
		{ id: 'reveal', label: 'Show in Finder' },
		{ id: 'info', label: 'Info' },
		{ id: 'trash', label: 'Move to Trash' },
	];
	let selectedAction = $state(0);
	let renameValue = $state('');
	let renameInput: HTMLInputElement | undefined = $state();

	// the viewer: a picture or a text file over the list
	type Shown =
		| { entry: Entry; kind: 'image'; url: string }
		// `text` is edited in place, `saved` is what the file holds
		| { entry: Entry; kind: 'text'; text: string; saved: string; truncated: boolean };
	let shown: Shown | null = $state(null);
	let textArea: HTMLTextAreaElement | undefined = $state();
	let saveTimer: ReturnType<typeof setTimeout> | null = null;
	let edited = false;

	let toast = $state('');
	let toastTimer: ReturnType<typeof setTimeout> | null = null;

	function showToast(text: string) {
		toast = text;
		if (toastTimer) clearTimeout(toastTimer);
		toastTimer = setTimeout(() => (toast = ''), 1400);
	}

	// ── sorting: ⌃⌘1 name, ⌃⌘2 kind, ⌃⌘3 date, ⌃⌘4 size; the same keys again turn the order round ──
	type SortKey = 'name' | 'kind' | 'date' | 'size';
	const sortKeys: SortKey[] = ['name', 'kind', 'date', 'size'];
	// the way each starts: names A to Z, kinds A to Z, the newest first, the biggest first
	const firstWay: Record<SortKey, 1 | -1> = { name: 1, kind: 1, date: -1, size: -1 };
	function readSort(): { key: SortKey; way: 1 | -1 } {
		try {
			const saved = JSON.parse(localStorage.getItem('sort') ?? '');
			if (sortKeys.includes(saved.key) && (saved.way === 1 || saved.way === -1)) return saved;
		} catch {}
		return { key: 'name', way: 1 };
	}
	let sort = $state(readSort());
	const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
	const extOf = (e: Entry) => (e.isDir ? '' : (e.name.match(/\.([^.]+)$/)?.[1] ?? '').toLowerCase());
	/** folders stay on top; inside them and the files, the chosen order, then the name */
	function sorted(list: Entry[]): Entry[] {
		const { key, way } = sort;
		const byName = (a: Entry, b: Entry) => collator.compare(a.name, b.name);
		const by = (a: Entry, b: Entry): number => {
			if (key === 'kind') return collator.compare(extOf(a), extOf(b));
			if (key === 'date') return (a.modified ?? 0) - (b.modified ?? 0);
			if (key === 'size') {
				// a folder not measured yet goes to the end either way
				const x = sizeOf(a), y = sizeOf(b);
				if (x === null || y === null) return x === y ? 0 : x === null ? -way : way;
				return x - y;
			}
			return byName(a, b);
		};
		return [...list].sort((a, b) => Number(b.isDir) - Number(a.isDir) || way * by(a, b) || byName(a, b));
	}
	/** sorts by `key`; again by the same, the other way round; the selection stays on its item */
	function sortBy(key: SortKey) {
		const keep = current?.path;
		sort = { key, way: sort.key === key ? (-sort.way as 1 | -1) : firstWay[key] };
		try {
			localStorage.setItem('sort', JSON.stringify(sort));
		} catch {}
		const words: Record<SortKey, [string, string]> = {
			name: ['A to Z', 'Z to A'],
			kind: ['A to Z', 'Z to A'],
			date: ['oldest first', 'newest first'],
			size: ['smallest first', 'biggest first'],
		};
		showToast(`By ${key}, ${words[key][sort.way === 1 ? 0 : 1]}`);
		keepSelection(keep);
	}
	function keepSelection(path: string | undefined) {
		const i = path ? visible.findIndex(e => e.path === path) : -1;
		if (i >= 0) selected = i;
	}

	let visible = $derived.by(() => {
		const q = query.trim().toLowerCase();
		const here = entries.filter(e => inMode(e, mode));
		return sorted(q ? here.filter(e => e.name.toLowerCase().includes(q)) : here);
	});
	let current: Entry | undefined = $derived(visible[selected]);
	// what the viewer steps through: the pictures (VIEW), the texts (TEXT), both (FILE's quick look)
	let viewable = $derived(visible.filter(e => !e.isDir && (kindOf(e.name) === 'image' || kindOf(e.name) === 'text')));
	let title = $derived(cwd ? (flat ? `${nameOf(cwd)} · all inside` : nameOf(cwd)) : '');
	// the home folder is the top of ReFile: BACK disappears there
	let home = $state('');
	let canGoBack = $derived(
		locked
			? flat === null && cwd !== lockRoot && cwd.startsWith(lockRoot.replace(/\/$/, '') + '/')
			: flat !== null || (cwd !== '' && cwd !== home && parentOf(cwd) !== null),
	);

	// ── navigation ──

	/** Shows `path`; selects the item called `selectName` when given. */
	async function navigate(path: string, selectName?: string) {
		try {
			const list = await files.list(path);
			flat = null;
			cwd = path;
			entries = list;
			listError = '';
			query = '';
			const idx = selectName ? visible.findIndex(e => e.name === selectName) : -1;
			selected = idx >= 0 ? idx : 0;
			await scrollSelectedIntoView();
		} catch (e) {
			listError = `No access to “${nameOf(path)}”.`;
		}
	}

	/** Every file inside `root`, at any depth, as one list (an "all inside" window). */
	async function showTree(root: string) {
		try {
			const list = await files.tree(root);
			flat = root;
			cwd = root;
			entries = list;
			listError = '';
			query = '';
			selected = 0;
		} catch (e) {
			listError = String(e);
		}
	}

	/** ⇧Enter, ⇧F / T / V / P: the folder selected (or this one) in a new window, everything inside it at any depth, in `m` */
	function openTree(m: Mode) {
		const root = current?.isDir ? current.path : cwd;
		if (root) invoke('new_window', { tree: root, mode: m });
	}

	// ── folders' sizes: measured in the background, two at a time, the folder in view first ──
	let sizes: Record<string, number> = $state({});
	let waiting: string[] = [];
	let measuring = 0;
	function measureNext() {
		while (measuring < 2 && waiting.length) {
			const path = waiting.shift()!;
			measuring++;
			files
				.folderSize(path)
				.then(bytes => {
					// sorted by size, the list moves as sizes come: the selection keeps to its item
					const keep = current?.path;
					sizes[path] = bytes;
					if (sort.key === 'size') keepSelection(keep);
				})
				.catch(() => {})
				.finally(() => {
					measuring--;
					measureNext();
				});
		}
	}
	/** these folders measured next (the ones asked for before and not yet begun are dropped) */
	function measure(paths: string[]) {
		waiting = paths.filter(p => !(p in sizes));
		measureNext();
	}
	$effect(() => {
		measure(entries.filter(e => e.size === null).map(e => e.path));
	});
	// a folder (or an app) shown on its own, in the info popup or the right column: measured first
	$effect(() => {
		for (const one of [info, previewInfo]) {
			if (one && one.size === null && !(one.path in sizes) && !waiting.includes(one.path)) {
				waiting.unshift(one.path);
				measureNext();
			}
		}
	});
	/** a file's size, or a folder's once measured */
	const sizeOf = (entry: { path: string; size: number | null }) => entry.size ?? sizes[entry.path] ?? null;

	/** Re-reads the current folder, keeping the selection on the same item when it still exists. */
	async function reload(selectName = current?.name) {
		if (!cwd) return;
		try {
			// the folders here measured again: something in them may have changed
			for (const e of entries) delete sizes[e.path];
			entries = flat ? await files.tree(flat) : await files.list(cwd);
			listError = '';
			const idx = selectName ? visible.findIndex(e => e.name === selectName) : -1;
			selected = idx >= 0 ? idx : Math.min(selected, Math.max(visible.length - 1, 0));
		} catch {
			listError = `No access to “${nameOf(cwd)}”.`;
		}
	}

	function back() {
		if (!canGoBack) return;
		// out of "all inside": the folder itself
		if (flat) return navigate(flat);
		const parent = parentOf(cwd);
		if (parent) navigate(parent, nameOf(cwd));
	}

	/**
	 * Folders open in place. A file goes to a new window of its own, in its mode, named after it; in a
	 * window opened for a file, the folder's others open there. What isn't ReFile's opens in the Mac's app.
	 */
	async function openEntry(entry: Entry | undefined = current) {
		if (!entry) return;
		if (entry.isDir) return navigate(entry.path);
		const its = modeOf(kindOf(entry.name));
		if (!its) return files.open(entry.path);
		if (!opened?.path && !flat) return invoke('new_window', { open: entry.path, mode: its });
		await openHere(entry);
	}

	/** A file opened in its mode, in this window: shown, read, played. False when it can't be. */
	async function openHere(entry: Entry): Promise<boolean> {
		const kind = kindOf(entry.name);
		if (kind === 'image' || kind === 'text') return show(entry);
		if (kind === 'book') {
			closeViewer();
			reading = { path: entry.path, title: entry.name.replace(/\.[^.]+$/, ''), format: bookFormat(entry.name) };
			return true;
		}
		const same = visible.filter(e => !e.isDir && kindOf(e.name) === kind);
		const start = Math.max(0, same.indexOf(entry));
		if (kind === 'video') {
			invoke('pause_music').catch(() => {});
			video = { paths: same.map(e => e.path), start };
			return true;
		}
		if (kind === 'audio') {
			await playPanel?.playFiles(same.map(e => e.path), start);
			return true;
		}
		return false;
	}

	/** Esc, CLOSE: the viewer goes (a text saved first). */
	function leaveViewer() {
		closeViewer();
	}

	/** Puts `entry` in the viewer; false when it can't be shown (not text after all, too big…). */
	async function show(entry: Entry): Promise<boolean> {
		try {
			let next: Shown;
			if (kindOf(entry.name) === 'image') {
				const bytes = await files.readFile(entry.path);
				next = { entry, kind: 'image', url: URL.createObjectURL(new Blob([bytes], { type: imageType(entry.name) })) };
			} else {
				const { text, truncated } = await files.readText(entry.path);
				next = { entry, kind: 'text', text, saved: text, truncated };
			}
			closeViewer();
			shown = next;
			return true;
		} catch {
			return false;
		}
	}

	function closeViewer() {
		save();
		if (shown?.kind === 'image') URL.revokeObjectURL(shown.url);
		shown = null;
		// sizes and dates changed with the edits
		if (edited) reload();
		edited = false;
	}

	/** Writes the text's edits, if any. Only whole files: a file shown cut at a megabyte stays as it is. */
	async function save() {
		if (saveTimer) clearTimeout(saveTimer);
		saveTimer = null;
		const doc = shown;
		if (doc?.kind !== 'text' || doc.truncated || doc.text === doc.saved) return;
		const text = doc.text;
		try {
			await files.writeText(doc.entry.path, text);
			doc.saved = text;
			edited = true;
		} catch {
			showToast('NOT SAVED');
		}
	}

	// typing saves itself a moment after it stops
	$effect(() => {
		if (shown?.kind !== 'text' || shown.text === shown.saved) return;
		if (saveTimer) clearTimeout(saveTimer);
		saveTimer = setTimeout(save, 700);
	});

	/** ← / → in the viewer: the previous / next picture or text of the folder, the selection following. */
	async function stepViewer(delta: number) {
		if (!shown || viewable.length < 2) return;
		const at = viewable.findIndex(e => e.path === shown!.entry.path);
		const next = viewable[(at + delta + viewable.length) % viewable.length];
		if (await show(next)) {
			selected = visible.indexOf(next);
			await scrollSelectedIntoView();
		}
	}

	/** In COLM view, clicking an item in the right column steps into the folder and selects it. */
	async function openFromPreview(entry: Entry) {
		if (!current?.isDir) return;
		await navigate(current.path, entry.name);
	}

	async function move(delta: number) {
		if (visible.length === 0) return;
		selected = (selected + delta + visible.length) % visible.length;
		await scrollSelectedIntoView();
	}

	async function scrollSelectedIntoView() {
		await tick();
		mainList?.querySelector('.row.active')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
	}

	// VIEW, as ReBook's library: the titles on the left, on the right the picture or the book's cover,
	// big, with what it is under it; a folder shows its pictures and books, small. Always in columns.
	// TEXT the same: the start of the text as a page, its lines under it; a folder's texts, small
	let layout: View = $derived(mode === 'view' || mode === 'text' ? 'colm' : view);
	let page: { text: string; lines: number } | null = $state(null);
	let pageError = $state(false);
	/** a folder's texts' first lines, as they come */
	let heads: Record<string, string | null> = $state({});
	let textThumbs = $derived(preview && mode === 'text' ? sorted(preview).filter(e => !e.isDir && inMode(e, 'text')).slice(0, 40) : []);
	$effect(() => {
		const list = textThumbs;
		let gone = false;
		(async () => {
			for (const e of list) {
				if (gone) return;
				if (untrack(() => e.path in heads)) continue;
				const head = await files.textHead(e.path, 700).then(h => h.text, () => null);
				if (!gone) heads[e.path] = head;
			}
		})();
		return () => (gone = true);
	});
	let picture: string | null = $state(null);
	let pictureSize: { width: number; height: number } | null = $state(null);
	function setPicture(url: string | null) {
		picture = url;
		pictureSize = null;
	}
	/** a folder's covers, drawn as they come (books: cachedCover; pictures are their own) */
	let covers: Record<string, string | null> = $state({});
	const formatNames: Record<string, string> = { pdf: 'PDF', epub: 'EPUB', cbz: 'Comic', cbr: 'Comic' };
	function bookNote(path: string): string {
		const { progress, position } = placeOf(path);
		if (position === null) return 'New';
		return progress >= 0.999 ? 'Finished' : `${Math.round(progress * 100)}% read`;
	}
	const extName = (name: string) => (name.match(/\.([^.]+)$/)?.[1] ?? '').toUpperCase();
	// what a folder holds, for the small pictures: its pictures and books, the first 60
	let thumbs = $derived(preview && mode === 'view' ? sorted(preview).filter(e => !e.isDir && inMode(e, 'view')).slice(0, 60) : []);
	$effect(() => {
		const list = thumbs;
		let gone = false;
		(async () => {
			for (const e of list) {
				if (gone) return;
				if (kindOf(e.name) !== 'book' || untrack(() => e.path in covers)) continue;
				const url = await cachedCover(e.path, bookFormat(e.name));
				if (!gone) covers[e.path] = url;
			}
		})();
		return () => (gone = true);
	});

	// load the right column for the selected item (latest request wins)
	let previewToken = 0;
	$effect(() => {
		const entry = current;
		const token = ++previewToken;
		preview = null;
		previewInfo = null;
		previewError = '';
		setPicture(null);
		page = null;
		pageError = false;
		if (!entry || layout !== 'colm') return;
		const kind = entry.isDir ? 'folder' : kindOf(entry.name);
		// FILE shows a look too: the picture, the cover, the text's start, a video's first frame
		const looks = mode === 'file' || mode === 'view';
		if (looks && kind === 'image') setPicture(convertFileSrc(entry.path));
		if ((mode === 'text' || mode === 'file') && kind === 'text') {
			files.textHead(entry.path, 6000).then(
				head => token === previewToken && (page = head),
				() => token === previewToken && (pageError = true),
			);
		}
		if (looks && kind === 'book') {
			// a moment on the book first: running down the list doesn't draw every cover
			setTimeout(() => {
				if (token !== previewToken) return;
				cachedCover(entry.path, bookFormat(entry.name)).then(url => token === previewToken && setPicture(url));
			}, 150);
		}
		const load = entry.isDir ? files.list(entry.path) : files.info(entry.path);
		load.then(
			result => {
				if (token !== previewToken) return;
				if (entry.isDir) preview = result as Entry[];
				else previewInfo = result as Info;
			},
			() => {
				if (token === previewToken) previewError = 'No access.';
			},
		);
	});

	// ── actions ──

	function openNewFolder() {
		newName = 'New folder';
		popupError = '';
		popup = 'new';
		tick().then(() => newNameInput?.select());
	}

	async function createFolder() {
		try {
			const path = await files.createFolder(cwd, newName);
			popup = 'none';
			query = '';
			await reload(nameOf(path));
			await scrollSelectedIntoView();
		} catch (e) {
			popupError = String(e);
		}
	}

	function openDelete() {
		if (!current) return;
		popupError = '';
		popup = 'delete';
	}

	async function moveToTrash() {
		if (!current) return;
		try {
			await files.moveToTrash(current.path);
			popup = 'none';
			await reload('');
		} catch (e) {
			popupError = String(e);
		}
	}

	async function openInfo() {
		info = await files.info(current?.path ?? cwd).catch(() => null);
		popup = 'info';
	}

	function closePopup() {
		popup = 'none';
	}

	function openActions(index = selected) {
		if (!visible[index]) return;
		selected = index;
		selectedAction = 0;
		popupError = '';
		popup = 'actions';
	}

	async function runAction(id: ActionId) {
		const entry = current;
		if (!entry) return;
		popupError = '';
		try {
			switch (id) {
				case 'open':
					closePopup();
					await openEntry(entry);
					break;
				case 'rename': {
					renameValue = entry.name;
					popup = 'rename';
					await tick();
					// select the name without its extension, like Finder
					const dot = entry.isDir ? -1 : entry.name.lastIndexOf('.');
					renameInput?.focus();
					renameInput?.setSelectionRange(0, dot > 0 ? dot : entry.name.length);
					break;
				}
				case 'compress': {
					const zip = await files.compress(entry.path);
					closePopup();
					await reload(nameOf(zip));
					await scrollSelectedIntoView();
					break;
				}
				case 'duplicate': {
					const copy = await files.duplicate(entry.path);
					closePopup();
					await reload(nameOf(copy));
					await scrollSelectedIntoView();
					break;
				}
				case 'copy':
					await navigator.clipboard.writeText(entry.path);
					closePopup();
					showToast('COPIED');
					break;
				case 'reveal':
					closePopup();
					await files.reveal(entry.path);
					break;
				case 'info':
					await openInfo();
					break;
				case 'trash':
					openDelete();
					break;
			}
		} catch (e) {
			popupError = String(e);
		}
	}

	async function renameItem() {
		if (!current) return;
		try {
			const path = await files.rename(current.path, renameValue);
			popup = 'none';
			query = '';
			await reload(nameOf(path));
			await scrollSelectedIntoView();
		} catch (e) {
			popupError = String(e);
		}
	}

	// ── keyboard ──

	function isTyping(e: KeyboardEvent) {
		const tag = (e.target as HTMLElement)?.tagName;
		return tag === 'INPUT' || tag === 'TEXTAREA';
	}

	function handleKeydown(e: KeyboardEvent) {
		// popups are modal: Enter confirms, Esc closes, nothing else reacts
		if (popup !== 'none') {
			if (e.key === 'Escape') {
				e.preventDefault();
				closePopup();
			} else if (popup === 'actions' && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
				e.preventDefault();
				const n = actions.length;
				selectedAction = (selectedAction + (e.key === 'ArrowDown' ? 1 : -1) + n) % n;
			} else if (e.key === 'Enter') {
				e.preventDefault();
				if (popup === 'delete') moveToTrash();
				else if (popup === 'new') createFolder();
				else if (popup === 'rename') renameItem();
				else if (popup === 'actions') runAction(actions[selectedAction].id);
				else closePopup();
			}
			return;
		}

		const mod = e.metaKey || e.ctrlKey;

		// a book and a video have their own keys (Reader.svelte, Video.svelte)
		if (reading || video) return;

		if (shown) {
			// in the text: it's typing, but for Esc (close) and ⌘S
			if (e.target === textArea) {
				if (e.key === 'Escape') {
					e.preventDefault();
					leaveViewer();
				} else if (mod && e.key === 's') {
					e.preventDefault();
					save();
				}
				return;
			}
			if (e.key === 'Escape' || e.key === ' ') {
				e.preventDefault();
				leaveViewer();
			} else if (e.key.startsWith('Arrow')) {
				e.preventDefault();
				stepViewer(e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : -1);
			}
			return;
		}

		// PLAY's own keys first (lib/play/Play.svelte): the player, the tabs, the songs and the radio
		if (mode === 'play' && playPanel?.key(e, e.target === searchInput)) return;
		if (!browsing) {
			if (e.code === 'Slash' && !isTyping(e)) {
				e.preventDefault();
				searchInput?.focus();
			} else if (e.target === searchInput && e.key === 'Escape') {
				query = '';
				searchInput?.blur();
			} else if (!isTyping(e) && !mod && !e.altKey) modeKey(e);
			return;
		}

		// in the search field: arrows move through results, Enter opens, Esc clears
		if (e.target === searchInput) {
			if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
				e.preventDefault();
				move(e.key === 'ArrowDown' ? 1 : -1);
			} else if (e.key === 'Enter') {
				e.preventDefault();
				openEntry();
			} else if (e.key === 'Escape') {
				query = '';
				searchInput?.blur();
			}
			return;
		}
		if (isTyping(e)) return;

		if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
			e.preventDefault();
			move(e.key === 'ArrowDown' ? 1 : -1);
		} else if (e.key === 'ArrowRight') {
			e.preventDefault();
			if (current?.isDir) openEntry();
		} else if (e.ctrlKey && e.metaKey && !e.altKey && /^Digit[1-4]$/.test(e.code)) {
			e.preventDefault();
			sortBy(sortKeys[Number(e.code.slice(5)) - 1]);
		} else if (e.key === 'Enter' && e.shiftKey) {
			e.preventDefault();
			openTree(mode);
		} else if (e.key === 'Enter' || (mod && e.key === 'o')) {
			e.preventDefault();
			openEntry();
		} else if (e.key === ' ' && current && !current.isDir) {
			// a quick look: only what the viewer shows
			e.preventDefault();
			if (viewable.includes(current)) show(current);
		} else if (!mod && !e.altKey && modeKey(e)) {
			// F / T / V / P: this folder in that mode
		} else if (e.key === 'ArrowLeft' || (mod && e.key === 'ArrowUp')) {
			e.preventDefault();
			back();
		} else if (e.key === 'Escape') {
			query = '';
		} else if (e.key === 'Backspace' || e.key === 'Delete') {
			e.preventDefault();
			openDelete();
		} else if (e.code === 'Slash') {
			e.preventDefault();
			searchInput?.focus();
		} else if (!mod && e.code === 'KeyN') {
			openNewFolder();
		} else if (!mod && e.code === 'KeyI') {
			if (mode === 'play') playPanel?.openInfo();
			else openInfo();
		} else if (!mod && e.code === 'KeyE') {
			openActions();
		} else if (!mod && e.code === 'KeyC') {
			view = 'colm';
		} else if (!mod && e.code === 'KeyL') {
			view = 'list';
		}
	}

	/** F / T / V / P: the mode; true when it was one of them */
	function modeKey(e: KeyboardEvent): boolean {
		const next = ({ KeyF: 'file', KeyT: 'text', KeyV: 'view', KeyP: 'play' } as Record<string, Mode>)[e.code];
		if (!next) return false;
		e.preventDefault();
		// with ⇧: the folder, all inside it, in a new window in that mode
		if (e.shiftKey) openTree(next);
		else setMode(next);
		// (a locked window keeps its mode: setMode does nothing there)
		return true;
	}

	// how full the disk is, 0…1, as the line under the search
	let disk = $state<{ total: number; free: number } | null>(null);
	const diskFull = $derived(disk && disk.total > 0 ? 1 - disk.free / disk.total : 0);
	const gb = (bytes: number) => `${Math.round(bytes / 1e9)} GB`;
	const readDisk = () => files.diskSpace().then(d => (disk = d)).catch(() => {});

	// how busy the Mac is, 0…1: the processor on the left, the memory on the right
	let load = $state<{ cpu: number; memory: number } | null>(null);
	const readLoad = () => files.load().then(l => (load = l)).catch(() => {});

	onMount(() => {
		readDisk();
		const diskTimer = setInterval(readDisk, 60_000);
		readLoad();
		const loadTimer = setInterval(readLoad, 2000);
		files.homeDir().then(async dir => {
			home = dir;
			if (opened?.tree) {
				lockRoot = opened.tree;
				return showTree(opened.tree);
			}
			const path = opened?.path;
			if (!path) return navigate(dir);
			lockRoot = parentOf(path) ?? path;
			// the file's folder, in the file's mode, the file opened in it
			const its = modeOf(kindOf(nameOf(path)));
			if (its && !opened?.mode) mode = its;
			if (mode === 'play') playTab = 'folder';
			await navigate(parentOf(path) ?? path, nameOf(path));
			await tick();
			const entry = entries.find(e => e.path === path);
			if (!entry || !(await openHere(entry))) {
				// not one ReFile can show after all: the Mac's app then
				await files.open(path);
				if (!entry) getCurrentWindow().close();
			}
		});
		// files may change in other apps while ReFile is in the background
		const refresh = () => {
			reload();
			readDisk();
		};
		window.addEventListener('focus', refresh);
		return () => {
			window.removeEventListener('focus', refresh);
			clearInterval(diskTimer);
			clearInterval(loadTimer);
		};
	});

	const shortcuts = [
		['F / T / V / P', 'This folder in FILE / TEXT / VIEW / PLAY'],
		['⇧ Enter, ⇧ F / T / V / P', 'The folder selected, all inside it (at any depth), in a new window'],
		['⌘ N', 'New window'],
		['↑ / ↓', 'Select'],
		['→ / Enter', 'Open (a file: in a new window, in its mode)'],
		['Space', 'A quick look at a picture or text, here'],
		['⌘ S', 'Save the text (it saves itself too)'],
		['←', 'Back'],
		['/', 'Search'],
		['C / L', 'Columns / List'],
		['⌃⌘ 1 / 2 / 3 / 4', 'Sort by name / kind / date / size (again: the other way)'],
		['N', 'New folder'],
		['I', 'Info'],
		['E / right click', 'Actions'],
		['Backspace', 'Move to Trash'],
	];
</script>

<svelte:window
	bind:innerWidth={winWidth}
	bind:innerHeight={winHeight}
	onkeydown={handleKeydown}
	oncontextmenu={e => {
		// the webview's own menu (Reload / Inspect) is not useful here; text fields keep theirs
		if ((e.target as HTMLElement)?.tagName !== 'INPUT') e.preventDefault();
	}}
/>

<WindowControls />

<!-- the view switch (the modes are on F / T / V / P; VIEW and TEXT always show columns) -->
<button class="side switch switch-colm" class:ink-mark-v={layout === 'colm'} onclick={() => (view = 'colm')} title="Columns (C)">COLM</button>
<button class="side switch switch-list" class:ink-mark-v={layout !== 'colm'} onclick={() => (view = 'list')} title="List (L)">LIST</button>

<!-- how busy the Mac is: the processor on the left, the memory on the right (in PLAY: PREV and NEXT) -->
{#if load && mode !== 'play'}
	<div class="gauge gauge-cpu" title="Processor {Math.round(load.cpu * 100)}%">
		<div class="gauge-used" style="height: {Math.min(load.cpu, 1) * 100}%"></div>
	</div>
	<span class="gauge-name gauge-cpu">CPU</span>
	<span class="gauge-number gauge-cpu">{Math.round(load.cpu * 100)}</span>
	<div class="gauge gauge-memory" title="Memory {Math.round(load.memory * 100)}%">
		<div class="gauge-used" style="height: {Math.min(load.memory, 1) * 100}%"></div>
	</div>
	<span class="gauge-name gauge-memory">RAM</span>
	<span class="gauge-number gauge-memory">{Math.round(load.memory * 100)}</span>
{/if}

<button class="side plain nav-info" onclick={() => (mode === 'play' ? playPanel?.openInfo() : openInfo())} title="Info (I)">INFO</button>
<button class="side plain nav-del" onclick={openDelete} disabled={!current} title="Move to Trash (Backspace)">DEL</button>
<!-- a small window: no buttons, the keys only -->

{#if mode === 'play'}
	<Play bind:this={playPanel} bind:tab={playTab} bind:query mini={tiny} toast={showToast} {shortcuts} />
{/if}

<main class="browser fade-in" class:play={mode === 'play'} class:hidden={!browsing}>
	{#if mode !== 'play'}<h1 class="title" title={cwd}>{title}</h1>{/if}

	{#if layout === 'colm'}
		<div class="column left scroll" bind:this={mainList} use:scrollFade>
			{#each visible as entry, i (entry.path)}
				<button
					class="row"
					class:active={i === selected}
					onclick={() => (selected = i)}
					ondblclick={() => openEntry(entry)}
					oncontextmenu={() => openActions(i)}
				>
					<span class="name" class:ink-mark={i === selected}>{entry.name}</span>
				</button>
			{:else}
				<p class="empty">{listError || (query ? 'Nothing found.' : 'Empty folder.')}</p>
			{/each}
		</div>

		<div class="column right scroll" use:scrollFade>
			{#if previewError}
				<p class="empty">{previewError}</p>
			{:else if preview && thumbs.length}
				<!-- VIEW: a folder's pictures and books, small, the click opens its folder on it -->
				<div class="thumbs">
					{#each thumbs as entry (entry.path)}
						{@const src = kindOf(entry.name) === 'image' ? convertFileSrc(entry.path) : covers[entry.path]}
						<button class="thumb" onclick={() => openFromPreview(entry)} title={entry.name}>
							{#if src}
								<img {src} alt="" loading="lazy" draggable="false" />
							{:else}
								<span class="thumb-blank">{extName(entry.name)}</span>
							{/if}
							<span class="thumb-name">{entry.name}</span>
						</button>
					{/each}
				</div>
			{:else if preview && textThumbs.length}
				<!-- TEXT: a folder's texts, as small pages of their first lines -->
				<div class="thumbs">
					{#each textThumbs as entry (entry.path)}
						<button class="thumb" onclick={() => openFromPreview(entry)} title={entry.name}>
							{#if heads[entry.path] === null}
								<span class="thumb-blank">{extName(entry.name) || 'TEXT'}</span>
							{:else}
								<pre class="thumb-page">{heads[entry.path] ?? ''}</pre>
							{/if}
							<span class="thumb-name">{entry.name}</span>
						</button>
					{/each}
				</div>
			{:else if preview}
				{#each sorted(preview).filter(e => inMode(e, mode)) as entry (entry.path)}
					<button class="row" onclick={() => openFromPreview(entry)}>
						<span class="name">{entry.name}</span>
					</button>
				{:else}
					<p class="empty">Empty.</p>
				{/each}
			{:else if previewInfo && mode === 'view'}
				<!-- VIEW: the picture or the cover, big, and what it is under it (as ReBook's) -->
				{@const kind = kindOf(previewInfo.name)}
				<section class="look">
					{#if picture}
						<img
							class="look-picture"
							class:page={kind === 'book'}
							src={picture}
							alt={previewInfo.name}
							draggable="false"
							onload={e => {
								const img = e.currentTarget as HTMLImageElement;
								pictureSize = { width: img.naturalWidth, height: img.naturalHeight };
							}}
							onerror={() => setPicture(null)}
						/>
					{:else}
						<div class="look-blank"><span>{previewInfo.name.replace(/\.[^.]+$/, '')}</span></div>
					{/if}
					<p class="look-meta">
						{#if kind === 'book'}
							{formatNames[bookFormat(previewInfo.name)] ?? extName(previewInfo.name)} · {bookNote(previewInfo.path)} · {formatSize(sizeOf(previewInfo))}
						{:else}
							{extName(previewInfo.name)}{#if pictureSize} · {pictureSize.width} × {pictureSize.height}{/if} · {formatSize(sizeOf(previewInfo))}
						{/if}
					</p>
				</section>
			{:else if previewInfo && mode === 'text'}
				<!-- TEXT: the start of the text as a page, and what it is under it -->
				<section class="look">
					{#if page}
						<pre class="look-page">{page.text}</pre>
					{:else if pageError}
						<div class="look-blank"><span>Not text after all.</span></div>
					{/if}
					<p class="look-meta">
						{extName(previewInfo.name) || 'TEXT'}{#if page} · {page.lines} {page.lines === 1 ? 'line' : 'lines'}{/if} · {formatSize(sizeOf(previewInfo))}
					</p>
				</section>
			{:else if previewInfo}
				<!-- FILE: what the file holds, over its details -->
				{@const kind = kindOf(previewInfo.name)}
				{#if mode === 'file'}
					{#if (kind === 'image' || kind === 'book') && picture}
						<img class="file-look" class:page={kind === 'book'} src={picture} alt={previewInfo.name} draggable="false" onerror={() => setPicture(null)} />
					{:else if kind === 'text' && page}
						<pre class="look-page file-page">{page.text}</pre>
					{:else if kind === 'video'}
						<!-- svelte-ignore a11y_media_has_caption -->
						<video class="file-look" src="{convertFileSrc(previewInfo.path)}#t=0.5" preload="metadata" muted playsinline></video>
					{/if}
				{/if}
				<dl class="details">
					<dt>Kind</dt><dd>{previewInfo.kind}</dd>
					<dt>Size</dt><dd>{formatSize(sizeOf(previewInfo))}</dd>
					<dt>Modified</dt><dd>{formatDate(previewInfo.modified)}</dd>
					<dt>Created</dt><dd>{formatDate(previewInfo.created)}</dd>
				</dl>
			{/if}
		</div>
	{:else}
		<div class="table scroll" bind:this={mainList} use:scrollFade>
			{#each visible as entry, i (entry.path)}
				<button
					class="row table-row"
					class:active={i === selected}
					onclick={() => (selected = i)}
					ondblclick={() => openEntry(entry)}
					oncontextmenu={() => openActions(i)}
				>
					<span class="cell-name"><span class="name" class:ink-mark={i === selected}>{entry.name}</span></span>
					<span class="cell size">{formatSize(sizeOf(entry))}</span>
					<span class="cell">{formatDate(entry.modified)}</span>
				</button>
			{:else}
				<p class="empty">{listError || (query ? 'Nothing found.' : 'Empty folder.')}</p>
			{/each}
		</div>
	{/if}

	{#if disk && mode !== 'play'}
		<div class="disk" title="{gb(disk.total - disk.free)} of {gb(disk.total)} used, {gb(disk.free)} free">
			<div class="disk-used" style="width: {diskFull * 100}%"></div>
		</div>
		<span class="disk-number disk-used-number">{Math.round((disk.total - disk.free) / 1e9)}</span>
		<span class="disk-number disk-name">DISC</span>
		<span class="disk-number disk-free-number">{Math.round(disk.free / 1e9)}</span>
	{/if}
</main>

<!-- the search: under the list; in PLAY, the title (the folder, or what the tab holds) -->
{#if !(mode === 'play' && tiny)}
	<input
		bind:this={searchInput}
		bind:value={query}
		class="search"
		class:top={mode === 'play'}
		type="text"
		placeholder={mode !== 'play' ? 'Search' : playTab === 'folder' ? title : playTab === 'songs' ? 'Search songs' : 'Search stations'}
		title="Search (/)"
		oninput={() => (selected = 0)}
	/>
{/if}

{#if reading}
	<Reader book={reading} onclose={() => (reading = null)} />
{/if}

{#if video}
	<Video paths={video.paths} start={video.start} onclose={() => (video = null)} />
{/if}

{#if popup === 'delete' && current}
	<Popup onclose={closePopup}>
		<p class="pop-text">Move “{current.name}” to Trash?</p>
		{#if popupError}<p class="pop-error">{popupError}</p>{/if}
		<div class="pop-actions">
			<button class="pop-btn" onclick={moveToTrash}>YES</button>
			<button class="pop-btn" onclick={closePopup}>NO</button>
		</div>
	</Popup>
{:else if popup === 'new'}
	<Popup onclose={closePopup}>
		<p class="pop-heading">NEW FOLDER</p>
		<div class="pop-divider"></div>
		<input bind:this={newNameInput} bind:value={newName} class="name-input" type="text" maxlength="255" />
		{#if popupError}<p class="pop-error">{popupError}</p>{/if}
		<div class="pop-actions">
			<button class="pop-btn" onclick={createFolder}>CREATE</button>
			<button class="pop-btn" onclick={closePopup}>CANCEL</button>
		</div>
	</Popup>
{:else if popup === 'actions' && current}
	<Popup onclose={closePopup}>
		<p class="pop-text actions-name">{current.name}</p>
		<div class="pop-divider"></div>
		<div class="actions">
			{#each actions as action, i (action.id)}
				<button
					class="action"
					onclick={() => runAction(action.id)}
					onmouseenter={() => (selectedAction = i)}
				>
					<span class:ink-mark={i === selectedAction}>{action.label}</span>
				</button>
			{/each}
		</div>
		{#if popupError}<p class="pop-error">{popupError}</p>{/if}
	</Popup>
{:else if popup === 'rename' && current}
	<Popup onclose={closePopup}>
		<p class="pop-heading">RENAME</p>
		<div class="pop-divider"></div>
		<input bind:this={renameInput} bind:value={renameValue} class="name-input" type="text" maxlength="255" />
		{#if popupError}<p class="pop-error">{popupError}</p>{/if}
		<div class="pop-actions">
			<button class="pop-btn" onclick={renameItem}>RENAME</button>
			<button class="pop-btn" onclick={closePopup}>CANCEL</button>
		</div>
	</Popup>
{:else if popup === 'info'}
	<Popup onclose={closePopup}>
		<p class="pop-heading">RE:FILE</p>
		<div class="pop-divider"></div>
		{#if info}
			<p class="info-name"><span class="ink-mark">{info.name}</span></p>
			<dl class="details info-details">
				<dt>Kind</dt><dd>{info.kind}</dd>
				{#if info.isDir}
					<dt>Items</dt><dd>{info.items ?? '--'}</dd>
				{/if}
				<dt>Size</dt><dd>{formatSize(sizeOf(info))}</dd>
				<dt>Created</dt><dd>{formatDate(info.created)}</dd>
				<dt>Modified</dt><dd>{formatDate(info.modified)}</dd>
				<dt>Where</dt><dd class="path">{parentOf(info.path) ?? '/'}</dd>
			</dl>
			<div class="pop-divider"></div>
		{/if}
		<div class="shortcuts">
			{#each shortcuts as [key, desc]}
				<span class="key">{key}</span><span class="desc">{desc}</span>
			{/each}
		</div>
		<div class="pop-divider"></div>
		<p class="pop-footer">local · private · offline</p>
	</Popup>
{/if}

{#if shown}
	<div class="viewer">
		<h1 class="title" title={shown.entry.path}>{shown.entry.name}</h1>
		{#if shown.kind === 'image'}
			<div class="view-image">
				<img
					src={shown.url}
					alt={shown.entry.name}
					onerror={() => {
						// a picture WebKit can't draw: the Mac's app then
						const path = shown!.entry.path;
						files.open(path).finally(leaveViewer);
					}}
				/>
			</div>
		{:else}
			{#if shown.truncated}
				<pre class="view-text scroll" use:scrollFade>{shown.text}</pre>
			{:else}
				<textarea class="view-text scroll" bind:this={textArea} bind:value={shown.text} spellcheck="false" use:scrollFade
				></textarea>
			{/if}
		{/if}
		<p class="view-foot">
			{formatSize(shown.entry.size)}{#if shown.kind === 'text' && shown.truncated} · the first megabyte, not editable{/if}
			{#if viewable.length > 1}
				· {viewable.findIndex(e => e.path === shown!.entry.path) + 1} / {viewable.length}{/if}
		</p>
		<button class="side boxed nav-back" onclick={leaveViewer} title="Close (Esc)">CLOSE</button>
		<button class="viewer-close" onclick={leaveViewer} title="Close (Esc)">CLOSE</button>
	</div>
{/if}

{#if toast}
	<div class="toast"><span>{toast}</span></div>
{/if}

<style>
	.browser {
		position: fixed;
		inset: 0;
	}

	.title {
		position: absolute;
		top: 28px;
		left: 50%;
		transform: translateX(-50%);
		max-width: 50%;
		font-family: 'Kurale', serif;
		font-weight: 400;
		font-size: 24px;
		line-height: 32px;
		letter-spacing: 0.04em;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		color: var(--text);
	}

	/* ── side buttons, placed as in the reference ── */
	.switch-colm { left: calc(6.25% - 28px); top: calc(6.25% + 8px); }
	.switch-list { right: calc(6.25% - 28px); top: calc(6.25% + 8px); }
	.nav-info { left: calc(6.25% - 28px); bottom: 6.25%; }
	.nav-del { right: calc(6.25% - 28px); bottom: 6.25%; }

	/* plain buttons sit centred where a box would be */
	.side.plain { width: 42px; }

	/* PLAY's songs and radio, and its mini player: the browser steps aside */
	.browser.hidden { display: none; }
	/* in PLAY, between the tabs and the player */
	.browser.play .scroll {
		top: calc(6.25% + 64px);
		bottom: calc(6.25% + 112px);
	}

	.nav-back { left: calc(6.25% - 28px); top: 50%; transform: translateY(-50%); }

	/* the load lines, where BACK and NEW were: faint, filled from below as far as used (as on ReDesk) */
	.gauge {
		position: fixed;
		top: 50%;
		transform: translateY(-50%);
		width: 3px;
		height: 160px;
		border-radius: 1.5px;
		background: color-mix(in srgb, var(--text) 25%, transparent);
		overflow: hidden;
		display: flex;
		align-items: flex-end;
		z-index: 10;
	}

	.gauge-cpu { left: calc(6.25% - 8px); }
	.gauge-memory { right: calc(6.25% - 8px); }

	/* each line's number, in percent, under it, centred on it */
	.gauge-number {
		position: fixed;
		top: calc(50% + 92px);
		width: 40px;
		text-align: center;
		font-family: 'Kurale', serif;
		font-size: 13px;
		line-height: 16px;
		color: var(--muted);
		z-index: 10;
	}

	.gauge-number.gauge-cpu { left: calc(6.25% - 26.5px); }
	.gauge-number.gauge-memory { right: calc(6.25% - 26.5px); }

	/* what each line measures, over it, centred on it */
	.gauge-name {
		position: fixed;
		top: calc(50% - 108px);
		width: 40px;
		text-align: center;
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 10px;
		letter-spacing: 0.18em;
		text-indent: 0.18em;
		line-height: 16px;
		color: var(--muted);
		z-index: 10;
	}

	.gauge-name.gauge-cpu { left: calc(6.25% - 26.5px); }
	.gauge-name.gauge-memory { right: calc(6.25% - 26.5px); }

	.disk-number {
		position: absolute;
		left: 50%;
		bottom: calc(6.25% - 36px);
		transform: translateX(-50%);
		white-space: nowrap;
		font-family: 'Kurale', serif;
		font-size: 13px;
		line-height: 16px;
		color: var(--muted);
	}

	.gauge-used {
		width: 100%;
		border-radius: 1.5px;
		background: color-mix(in srgb, var(--text) 75%, transparent);
		transition: height 600ms ease;
	}

	.side:disabled { opacity: 0.3; pointer-events: none; }

	/* ── actions menu ── */
	.actions-name {
		font-size: 22px;
	}

	.actions {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 16px;
		/* room for the ink stroke on the selected action */
		padding: 0.3em 0.5em;
	}

	.action {
		background: transparent;
		border: none;
		padding: 0;
		font-family: 'Kurale', serif;
		font-size: 16px;
		line-height: 1.2;
		color: var(--text);
		text-align: left;
		cursor: pointer;
	}

	/* ── toast (like ReNote's SAVED) ── */
	.toast {
		position: fixed;
		top: 0;
		left: 50%;
		transform: translateX(-50%);
		width: 42px;
		padding: 1.5rem 0 calc(1.5rem - 0.6em);
		border: 2px solid var(--line);
		border-top: none;
		background: var(--bg) url('/noise.svg') repeat;
		display: flex;
		justify-content: center;
		z-index: 80;
		animation: toastIn 300ms cubic-bezier(0.22, 1, 0.36, 1) both;
	}

	.toast span {
		writing-mode: vertical-rl;
		text-orientation: upright;
		letter-spacing: 0.6em;
		font-size: 16px;
		line-height: 32px;
	}

	@keyframes toastIn {
		from { transform: translateX(-50%) translateY(-100%); }
		to { transform: translateX(-50%) translateY(0); }
	}

	/* ── lists ── */
	.scroll {
		position: absolute;
		top: calc(6.25% + 40px);
		bottom: calc(6.25% + 44px);
		overflow-y: auto;
		overflow-x: hidden;
		display: flex;
		flex-direction: column;
		gap: 22px;
		/* room for the ink stroke of the selected row, which the scroll box would clip */
		padding: 0.4em 0.6em;
	}

	.column.left { left: calc(21.3% - 0.6em); width: 26%; }
	.column.right { left: calc(50% - 0.6em); width: calc(50% - 6.25% - 60px); }

	.row {
		display: flex;
		align-items: center;
		min-width: 0;
		background: transparent;
		border: none;
		padding: 0;
		text-align: left;
		font-family: 'Kurale', serif;
		font-size: 16px;
		line-height: 1.2;
		color: var(--text);
		cursor: pointer;
		/* scrolled-to rows stop clear of the faded edges */
		scroll-margin: 56px 0;
		flex-shrink: 0;
	}

	.name {
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		min-width: 0;
		max-width: 100%;
	}

	.empty {
		font-family: 'Kurale', serif;
		font-size: 16px;
		color: var(--muted);
		opacity: 0.45;
	}

	/* ── list view ── */
	.table {
		left: 50%;
		transform: translateX(-50%);
		width: min(680px, calc(100% - 2 * (6.25% + 60px)));
	}

	.table-row {
		display: grid;
		grid-template-columns: minmax(0, 1fr) 110px 220px;
		column-gap: 24px;
		width: 100%;
	}

	.cell-name {
		display: flex;
		min-width: 0;
	}

	.cell {
		font-size: 16px;
		white-space: nowrap;
	}

	/* ── file details (right column / info) ── */
	.details {
		display: grid;
		grid-template-columns: auto 1fr;
		gap: 14px 20px;
		font-family: 'Kurale', serif;
		font-size: 16px;
	}

	.details dt {
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 12px;
		letter-spacing: 0.3em;
		text-transform: uppercase;
		opacity: 0.55;
		align-self: center;
	}

	.details .path {
		overflow-wrap: anywhere;
	}

	.info-name {
		font-family: 'Kurale', serif;
		font-size: 24px;
		text-align: center;
		overflow-wrap: anywhere;
	}

	.info-details {
		width: 100%;
	}

	/* ── search ── */
	.search {
		position: fixed;
		z-index: 5;
		left: 50%;
		bottom: calc(6.25% - 6px);
		transform: translateX(-50%);
		width: 360px;
		background: transparent;
		border: none;
		outline: none;
		font-family: 'Kurale', serif;
		font-size: 24px;
		line-height: 32px;
		text-align: center;
		color: var(--text);
	}

	/* PLAY: the search is the title */
	.search.top {
		top: 28px;
		bottom: auto;
	}

	.search::placeholder {
		color: var(--muted);
		opacity: 0.55;
	}

	/* how full the disk is: a faint line under the search, filled as far as used (as the lines on ReDesk) */
	.disk {
		position: absolute;
		left: 50%;
		bottom: calc(6.25% - 16px);
		transform: translateX(-50%);
		width: 360px;
		height: 3px;
		border-radius: 1.5px;
		background: color-mix(in srgb, var(--text) 25%, transparent);
		overflow: hidden;
	}

	/* by the line's ends, level with it: the gigabytes used on the left, free on the right (DISC under it) */
	.disk-number.disk-used-number,
	.disk-number.disk-free-number { bottom: calc(6.25% - 16px - 6.5px); }
	.disk-number.disk-used-number { left: calc(50% - 180px - 14px); transform: translateX(-100%); }
	.disk-number.disk-free-number { left: calc(50% + 180px + 14px); transform: none; }
	/* as the load lines' names (CPU, RAM) */
	.disk-number.disk-name {
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 10px;
		letter-spacing: 0.18em;
		text-indent: 0.18em;
	}

	.disk-used {
		height: 100%;
		border-radius: 1.5px;
		background: color-mix(in srgb, var(--text) 75%, transparent);
	}

	/* ── a small window: the two columns share it; the list keeps size and date while they fit ── */
	@media (max-width: 759px), (max-height: 559px) {
		.title {
			top: 12px;
			max-width: calc(100% - 200px);
			font-size: 18px;
		}

		.scroll {
			top: 52px;
			bottom: 52px;
		}

		.column.left { left: 40px; width: calc(50% - 50px); }
		.column.right { left: calc(50% + 10px); width: calc(50% - 50px); }

		.table { width: calc(100% - 80px); }
		.table-row { grid-template-columns: minmax(0, 1fr) 80px 150px; column-gap: 16px; }
		.cell { font-size: 14px; }
		/* the size sits in the middle of its column, between the name and the date */
		.cell.size { text-align: center; }

		.search {
			bottom: 8px;
			width: calc(100% - 200px);
			font-size: 18px;
			transition: opacity 200ms ease;
		}

		/* PLAY: the search at the top, the list between the tabs and the player */
		.search.top { top: 12px; }
		.browser.play .scroll {
			top: 76px;
			bottom: 128px;
		}

		/* no disk line in a small window */
		.disk {
			display: none;
		}

		/* nor load lines, nor their numbers */
		.gauge,
		.gauge-name,
		.gauge-number,
		.disk-number {
			display: none;
		}

		/* only in the window in use, while nothing is typed in it */
		:global(html.blurred) .search:placeholder-shown {
			opacity: 0;
			pointer-events: none;
		}
	}

	@media (max-width: 559px) {
		.table-row { grid-template-columns: minmax(0, 1fr) 80px; }
		.cell:last-child { display: none; }
	}

	/* ── viewer: over the list, under popups and the window buttons ── */
	.viewer {
		position: fixed;
		inset: 0;
		z-index: 40;
		background: var(--bg) url('/noise.svg') repeat;
	}

	.view-image {
		position: absolute;
		top: calc(6.25% + 40px);
		bottom: calc(6.25% + 44px);
		left: calc(6.25% + 60px);
		width: calc(100% - 2 * (6.25% + 60px));
		height: calc(100% - 2 * 6.25% - 84px);
		display: flex;
		align-items: center;
		justify-content: center;
	}

	/* at its own shape, so the rounded corners are the picture's */
	.view-image img {
		max-width: 100%;
		max-height: 100%;
		border-radius: 22px;
	}

	.view-text {
		left: calc(6.25% + 60px);
		right: calc(6.25% + 60px);
		display: block;
		margin: 0;
		font-family: 'SF Mono', Menlo, monospace;
		font-size: 13px;
		line-height: 1.6;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		color: var(--text);
	}

	/* the editor: a page of text, nothing around it (a textarea doesn't stretch between left and right) */
	textarea.view-text {
		width: calc(100% - 2 * (6.25% + 60px));
		height: calc(100% - 2 * 6.25% - 84px);
		padding: 0;
		border: none;
		outline: none;
		resize: none;
		background: transparent;
		caret-color: var(--text);
	}

	.view-foot {
		position: absolute;
		left: 50%;
		bottom: calc(6.25% - 6px);
		transform: translateX(-50%);
		margin: 0;
		font-family: 'Kurale', serif;
		font-size: 18px;
		line-height: 32px;
		white-space: nowrap;
		color: var(--muted);
		opacity: 0.7;
	}

	/* VIEW: the picture or the cover, big, in the middle of the column, what it is under it */
	.look {
		flex: 1;
		min-height: 0;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 18px;
	}

	.look-picture {
		max-width: 100%;
		max-height: calc(100% - 60px);
		min-height: 0;
		object-fit: contain;
		border-radius: 12px;
		box-shadow: 0 2px 18px rgba(0, 0, 0, 0.12);
	}

	.look-picture.page { border-radius: 6px; }

	.look-blank {
		width: min(260px, 100%);
		aspect-ratio: 2 / 3;
		border: 2px solid var(--line);
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 1.5rem;
		flex-shrink: 0;
	}

	.look-blank span {
		font-family: 'Kurale', serif;
		font-size: 22px;
		text-align: center;
		overflow-wrap: anywhere;
	}

	.look-meta {
		font-family: 'Kurale', serif;
		font-size: 16px;
		color: var(--muted);
		text-align: center;
		flex-shrink: 0;
	}

	/* FILE: the look over the details, smaller */
	.file-look {
		display: block;
		max-width: 100%;
		max-height: 46vh;
		margin-bottom: 30px;
		align-self: flex-start;
		flex-shrink: 0;
		object-fit: contain;
		border-radius: 12px;
		box-shadow: 0 2px 18px rgba(0, 0, 0, 0.12);
	}

	.file-look.page { border-radius: 6px; }

	.file-page {
		flex-shrink: 0;
		max-height: 46vh;
		margin-bottom: 30px;
	}

	/* TEXT: the start of a text, as a page */
	.look-page {
		width: 100%;
		max-height: calc(100% - 60px);
		min-height: 0;
		overflow: hidden;
		margin: 0;
		padding: 28px 32px;
		border-radius: 12px;
		box-shadow: 0 2px 18px rgba(0, 0, 0, 0.12);
		background: color-mix(in srgb, var(--bg) 92%, var(--text) 4%);
		font-family: 'SF Mono', Menlo, monospace;
		font-size: 12px;
		line-height: 1.6;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		color: var(--text);
		/* the page fades out at its foot, as more text goes on */
		mask-image: linear-gradient(to bottom, #000 80%, transparent);
	}

	.thumb-page {
		width: 100%;
		height: 150px;
		margin: 0;
		padding: 10px 11px;
		overflow: hidden;
		border-radius: 8px;
		box-shadow: 0 1px 10px rgba(0, 0, 0, 0.1);
		background: color-mix(in srgb, var(--bg) 92%, var(--text) 4%);
		font-family: 'SF Mono', Menlo, monospace;
		font-size: 7px;
		line-height: 1.5;
		white-space: pre-wrap;
		overflow-wrap: anywhere;
		text-align: left;
		color: var(--text);
		mask-image: linear-gradient(to bottom, #000 70%, transparent);
	}

	/* VIEW: a folder's pictures and books, small */
	.thumbs {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(120px, 1fr));
		gap: 22px 18px;
		flex-shrink: 0;
	}

	.thumb {
		display: flex;
		flex-direction: column;
		gap: 8px;
		min-width: 0;
		background: transparent;
		border: none;
		padding: 0;
		cursor: pointer;
		color: var(--text);
	}

	.thumb img,
	.thumb-blank {
		width: 100%;
		height: 150px;
		object-fit: cover;
		border-radius: 8px;
		box-shadow: 0 1px 10px rgba(0, 0, 0, 0.1);
	}

	.thumb-blank {
		display: flex;
		align-items: center;
		justify-content: center;
		border: 2px solid var(--line);
		box-shadow: none;
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 12px;
		letter-spacing: 0.3em;
	}

	.thumb-name {
		font-family: 'Kurale', serif;
		font-size: 13px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		text-align: left;
	}

	/* the small window's corner; the big one has the side button */
	.viewer-close {
		display: none;
	}

	@media (max-width: 759px), (max-height: 559px) {
		.view-image {
			top: 52px;
			bottom: 52px;
			left: 40px;
			width: calc(100% - 80px);
			height: calc(100% - 104px);
		}

		.view-text {
			left: 40px;
			right: 40px;
		}

		textarea.view-text {
			width: calc(100% - 80px);
			height: calc(100% - 104px);
		}

		.view-foot {
			bottom: 8px;
			font-size: 14px;
		}

		.viewer-close {
			display: none;
			position: fixed;
			top: 12px;
			right: 12px;
			background: transparent;
			border: none;
			padding: 0.4em 0.3em 0.1em;
			font-family: 'Noto Sans JP', sans-serif;
			font-size: 12px;
			letter-spacing: 0.3em;
			writing-mode: vertical-rl;
			text-orientation: upright;
			line-height: 1;
			color: var(--text);
			opacity: 0.6;
			cursor: pointer;
		}

		.viewer-close:hover {
			opacity: 1;
		}
	}

	/* ── popups ── */
	.name-input {
		width: 100%;
		background: transparent;
		border: none;
		outline: none;
		font-family: 'Kurale', serif;
		font-size: 24px;
		text-align: center;
		color: var(--text);
	}

	.pop-error {
		font-family: 'Kurale', serif;
		font-size: 15px;
		color: var(--error);
		text-align: center;
	}

	.shortcuts {
		display: grid;
		grid-template-columns: auto auto;
		gap: 8px 24px;
		font-size: 13px;
	}

	.shortcuts .key {
		font-family: 'Noto Sans JP', sans-serif;
		letter-spacing: 0.1em;
		text-align: right;
		opacity: 0.85;
	}

	.shortcuts .desc {
		font-family: 'Kurale', serif;
		opacity: 0.7;
	}

	.pop-footer {
		font-family: 'Kurale', serif;
		font-size: 13px;
		letter-spacing: 0.15em;
		opacity: 0.55;
	}
</style>
