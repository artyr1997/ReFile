<script lang="ts">
	import { onMount, tick } from 'svelte';
	import WindowControls from './lib/WindowControls.svelte';
	import Popup from './lib/Popup.svelte';
	import { scrollFade } from './lib/scrollFade';
	import { files, parentOf, nameOf, formatDate, formatSize } from './lib/files';
	import type { Entry, Info } from './lib/files';

	type View = 'colm' | 'list';
	type PopupKind = 'none' | 'delete' | 'new' | 'info';

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

	let visible = $derived.by(() => {
		const q = query.trim().toLowerCase();
		return q ? entries.filter(e => e.name.toLowerCase().includes(q)) : entries;
	});
	let current: Entry | undefined = $derived(visible[selected]);
	let title = $derived(cwd ? nameOf(cwd) : '');
	let canGoBack = $derived(cwd !== '' && parentOf(cwd) !== null);

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

	/** Re-reads the current folder, keeping the selection on the same item when it still exists. */
	async function reload(selectName = current?.name) {
		if (!cwd) return;
		try {
			entries = await files.list(cwd);
			listError = '';
			const idx = selectName ? visible.findIndex(e => e.name === selectName) : -1;
			selected = idx >= 0 ? idx : Math.min(selected, Math.max(visible.length - 1, 0));
		} catch {
			listError = `No access to “${nameOf(cwd)}”.`;
		}
	}

	function back() {
		const parent = parentOf(cwd);
		if (parent) navigate(parent, nameOf(cwd));
	}

	async function openEntry(entry: Entry | undefined = current) {
		if (!entry) return;
		if (entry.isDir) await navigate(entry.path);
		else await files.open(entry.path);
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
			} else if (e.key === 'Enter') {
				e.preventDefault();
				if (popup === 'delete') moveToTrash();
				else if (popup === 'new') createFolder();
				else closePopup();
			}
			return;
		}

		const mod = e.metaKey || e.ctrlKey;

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
		} else if (!mod && e.code === 'KeyC') {
			view = 'colm';
		} else if (!mod && e.code === 'KeyL') {
			view = 'list';
		}
	}

	onMount(() => {
		files.homeDir().then(home => navigate(home));
		// files may change in other apps while ReFile is in the background
		const refresh = () => reload();
		window.addEventListener('focus', refresh);
		return () => window.removeEventListener('focus', refresh);
	});

	const shortcuts = [
		['↑ / ↓', 'Select'],
		['→ / Enter', 'Open'],
		['←', 'Back'],
		['/', 'Search'],
		['C / L', 'Columns / List'],
		['N', 'New folder'],
		['I', 'Info'],
		['Backspace', 'Move to Trash'],
	];
</script>

<svelte:window onkeydown={handleKeydown} />

<WindowControls />

<!-- view switch -->
<button class="side switch-colm {view === 'colm' ? 'boxed on' : 'plain'}" onclick={() => (view = 'colm')} title="Columns (C)">COLM</button>
<button class="side switch-list {view === 'list' ? 'boxed on' : 'plain'}" onclick={() => (view = 'list')} title="List (L)">LIST</button>

<button class="side boxed nav-back" onclick={back} disabled={!canGoBack} title="Back (←)">BACK</button>
<button class="side boxed nav-new" onclick={openNewFolder} title="New folder (N)">NEW</button>

<button class="side plain nav-info" onclick={openInfo} title="Info (I)">INFO</button>
<button class="side plain nav-del" onclick={openDelete} disabled={!current} title="Move to Trash (Backspace)">DEL</button>

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
					<dt>Size</dt><dd>{formatSize(previewInfo.size)}</dd>
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
				>
					<span class="cell-name"><span class="name" class:ink-mark={i === selected}>{entry.name}</span></span>
					<span class="cell">{formatDate(entry.modified)}</span>
					<span class="cell">{formatSize(entry.size)}</span>
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
</main>

{#if popup === 'delete' && current}
	<Popup onclose={closePopup}>
		<p class="pop-text">Move <span class="ink-mark">{current.name}</span> to Trash?</p>
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
				{:else}
					<dt>Size</dt><dd>{formatSize(info.size)}</dd>
				{/if}
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

<style>
	.browser {
		position: fixed;
		inset: 0;
	}

	.title {
		position: absolute;
		top: calc(6.25% - 2px);
		left: 50%;
		transform: translateX(-50%);
		max-width: 50%;
		font-family: 'Kurale', serif;
		font-weight: 400;
		font-size: 30px;
		line-height: 40px;
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
	.nav-new { right: calc(6.25% - 28px); top: 50%; transform: translateY(-50%); }
	.nav-info { left: calc(6.25% - 28px); bottom: 6.25%; }
	.nav-del { right: calc(6.25% - 28px); bottom: 6.25%; }

	/* plain buttons sit centred where a box would be */
	.side.plain { width: 42px; }

	.side:disabled { opacity: 0.3; pointer-events: none; }

	/* ── lists ── */
	.scroll {
		position: absolute;
		top: calc(6.25% + 132px);
		bottom: calc(6.25% + 72px);
		overflow-y: auto;
		overflow-x: hidden;
		display: flex;
		flex-direction: column;
		gap: 22px;
		/* room for the ink stroke of the selected row, which the scroll box would clip */
		padding: 0.4em 0.6em;
	}

	.column.left { left: calc(21.3% - 0.6em); width: 34%; }
	.column.right { left: calc(69.4% - 0.6em); width: calc(30.6% - 6.25% - 60px); }

	.row {
		display: flex;
		align-items: center;
		min-width: 0;
		background: transparent;
		border: none;
		padding: 0;
		text-align: left;
		font-family: 'Kurale', serif;
		font-size: 18px;
		line-height: 1.2;
		color: var(--text);
		cursor: url('/ink/hand.svg'), pointer;
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
		font-size: 18px;
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
		grid-template-columns: minmax(0, 1fr) 220px 110px;
		column-gap: 24px;
		width: 100%;
	}

	.cell-name {
		display: flex;
		min-width: 0;
	}

	.cell {
		font-size: 17px;
		white-space: nowrap;
	}

	/* ── file details (right column / info) ── */
	.details {
		display: grid;
		grid-template-columns: auto 1fr;
		gap: 14px 20px;
		font-family: 'Kurale', serif;
		font-size: 17px;
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
		font-size: 22px;
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
		font-size: 30px;
		line-height: 40px;
		text-align: center;
		color: var(--text);
	}

	.search::placeholder {
		color: var(--muted);
		opacity: 0.55;
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
		color: #b04a45;
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
