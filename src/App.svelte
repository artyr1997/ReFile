<script lang="ts">
	import { onMount, tick } from 'svelte';
	import WindowControls from './lib/WindowControls.svelte';
	import Popup from './lib/Popup.svelte';
	import { scrollFade } from './lib/scrollFade';
	import { files, parentOf, nameOf, formatDate, formatSize, kindOf, imageType } from './lib/files';
	import type { Entry, Info } from './lib/files';

	type View = 'colm' | 'list';
	type PopupKind = 'none' | 'delete' | 'new' | 'info' | 'actions' | 'rename';
	type ActionId = 'open' | 'rename' | 'duplicate' | 'compress' | 'copy' | 'reveal' | 'info' | 'trash';

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

	let visible = $derived.by(() => {
		const q = query.trim().toLowerCase();
		return q ? entries.filter(e => e.name.toLowerCase().includes(q)) : entries;
	});
	let current: Entry | undefined = $derived(visible[selected]);
	// what the viewer steps through
	let viewable = $derived(visible.filter(e => !e.isDir && (kindOf(e.name) === 'image' || kindOf(e.name) === 'text')));
	let title = $derived(cwd ? nameOf(cwd) : '');
	// the home folder is the top of ReFile: BACK disappears there
	let home = $state('');
	let canGoBack = $derived(cwd !== '' && cwd !== home && parentOf(cwd) !== null);

	// ── navigation ──

	/** Shows `path`; selects the item called `selectName` when given. */
	async function navigate(path: string, selectName?: string) {
		try {
			const list = await files.list(path);
			cwd = path;
			entries = list;
			listError = '';
			query = '';
			const idx = selectName ? list.findIndex(e => e.name === selectName) : -1;
			selected = idx >= 0 ? idx : 0;
			await scrollSelectedIntoView();
		} catch (e) {
			listError = `No access to “${nameOf(path)}”.`;
		}
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
				.then(bytes => (sizes[path] = bytes))
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
			entries = await files.list(cwd);
			listError = '';
			const idx = selectName ? visible.findIndex(e => e.name === selectName) : -1;
			selected = idx >= 0 ? idx : Math.min(selected, Math.max(visible.length - 1, 0));
		} catch {
			listError = `No access to “${nameOf(cwd)}”.`;
		}
	}

	function back() {
		if (!canGoBack) return;
		const parent = parentOf(cwd);
		if (parent) navigate(parent, nameOf(cwd));
	}

	/** Folders open in place, pictures and text in the viewer, music in ReSound, the rest with the Mac's app. */
	async function openEntry(entry: Entry | undefined = current) {
		if (!entry) return;
		if (entry.isDir) return navigate(entry.path);
		const kind = kindOf(entry.name);
		if (kind === 'audio') return files.openInReSound(entry.path);
		if ((kind === 'image' || kind === 'text') && (await show(entry))) return;
		await files.open(entry.path);
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

	// load the right column for the selected item (latest request wins)
	let previewToken = 0;
	$effect(() => {
		const entry = current;
		const token = ++previewToken;
		preview = null;
		previewInfo = null;
		previewError = '';
		if (!entry || view !== 'colm') return;
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

		if (shown) {
			// in the text: it's typing, but for Esc (close) and ⌘S
			if (e.target === textArea) {
				if (e.key === 'Escape') {
					e.preventDefault();
					closeViewer();
				} else if (mod && e.key === 's') {
					e.preventDefault();
					save();
				}
				return;
			}
			if (e.key === 'Escape' || e.key === ' ') {
				e.preventDefault();
				closeViewer();
			} else if (e.key.startsWith('Arrow')) {
				e.preventDefault();
				stepViewer(e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1 : -1);
			}
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
		} else if (e.key === 'Enter' || (mod && e.key === 'o')) {
			e.preventDefault();
			openEntry();
		} else if (e.key === ' ' && current && !current.isDir) {
			// a quick look: only what the viewer shows
			e.preventDefault();
			if (viewable.includes(current)) show(current);
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
			openInfo();
		} else if (!mod && e.code === 'KeyE') {
			openActions();
		} else if (!mod && e.code === 'KeyC') {
			view = 'colm';
		} else if (!mod && e.code === 'KeyL') {
			view = 'list';
		}
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
		files.homeDir().then(dir => {
			home = dir;
			navigate(dir);
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
		['↑ / ↓', 'Select'],
		['→ / Enter', 'Open'],
		['Space', 'Look at a picture or text'],
		['⌘ S', 'Save the text (it saves itself too)'],
		['←', 'Back'],
		['/', 'Search'],
		['C / L', 'Columns / List'],
		['N', 'New folder'],
		['I', 'Info'],
		['E / right click', 'Actions'],
		['Backspace', 'Move to Trash'],
	];
</script>

<svelte:window
	onkeydown={handleKeydown}
	oncontextmenu={e => {
		// the webview's own menu (Reload / Inspect) is not useful here; text fields keep theirs
		if ((e.target as HTMLElement)?.tagName !== 'INPUT') e.preventDefault();
	}}
/>

<WindowControls />

<!-- view switch -->
<button class="side switch switch-colm" class:ink-mark-v={view === 'colm'} onclick={() => (view = 'colm')} title="Columns (C)">COLM</button>
<button class="side switch switch-list" class:ink-mark-v={view === 'list'} onclick={() => (view = 'list')} title="List (L)">LIST</button>

<!-- how busy the Mac is: the processor on the left, the memory on the right (← goes back, N makes a folder) -->
{#if load}
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

<button class="side plain nav-info" onclick={openInfo} title="Info (I)">INFO</button>
<button class="side plain nav-del" onclick={openDelete} disabled={!current} title="Move to Trash (Backspace)">DEL</button>

<!-- a small window: the view switch where BACK is in a big one (← still goes back) -->
<button class="corner top-right" onclick={() => (view = view === 'colm' ? 'list' : 'colm')} title={view === 'colm' ? 'List (L)' : 'Columns (C)'}>
	{view === 'colm' ? 'LIST' : 'COLM'}
</button>
<button class="corner bottom-left" onclick={openInfo} title="Info (I)">INFO</button>
<button class="corner bottom-right" onclick={openNewFolder} title="New folder (N)">NEW</button>

<main class="browser fade-in">
	<h1 class="title" title={cwd}>{title}</h1>

	{#if view === 'colm'}
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
			{:else if preview}
				{#each preview as entry (entry.path)}
					<button class="row" onclick={() => openFromPreview(entry)}>
						<span class="name">{entry.name}</span>
					</button>
				{:else}
					<p class="empty">Empty.</p>
				{/each}
			{:else if previewInfo}
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

	<input
		bind:this={searchInput}
		bind:value={query}
		class="search"
		type="text"
		placeholder="Search"
		title="Search this folder (/)"
		oninput={() => (selected = 0)}
	/>
	{#if disk}
		<div class="disk" title="{gb(disk.total - disk.free)} of {gb(disk.total)} used, {gb(disk.free)} free">
			<div class="disk-used" style="width: {diskFull * 100}%"></div>
		</div>
		<span class="disk-number disk-used-number">{Math.round((disk.total - disk.free) / 1e9)}</span>
		<span class="disk-number disk-name">DISC</span>
		<span class="disk-number disk-free-number">{Math.round(disk.free / 1e9)}</span>
	{/if}
</main>

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
						closeViewer();
						files.open(path);
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
		<button class="side boxed nav-back" onclick={closeViewer} title="Close (Esc)">CLOSE</button>
		<button class="viewer-close" onclick={closeViewer} title="Close (Esc)">CLOSE</button>
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
	.nav-info { left: calc(6.25% - 28px); bottom: 6.25%; }
	.nav-del { right: calc(6.25% - 28px); bottom: 6.25%; }

	/* plain buttons sit centred where a box would be */
	.side.plain { width: 42px; }

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
		position: absolute;
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
			display: block;
			position: fixed;
			top: 12px;
			right: 12px;
			background: transparent;
			border: none;
			padding: 0.3em 0.4em;
			font-family: 'Noto Sans JP', sans-serif;
			font-size: 12px;
			letter-spacing: 0.3em;
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
