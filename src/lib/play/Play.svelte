<script lang="ts">
	import { t, tx } from '../lang.svelte';
	// PLAY (what RePlay was): three views (1 / 2 / 3; no tabs shown), FOLDER (ReFile's own list, of music and
	// videos only: App.svelte), SONGS (every song of the music folder, A to Z) and RADIO (genres and
	// their stations); the player under them all, < and > beside PLAY. A small window is the mini
	// player. App.svelte hands the keys here first (key()).
	import { onMount, tick } from 'svelte';
	import { listen } from '@tauri-apps/api/event';
	import { getCurrentWindow, LogicalSize } from '@tauri-apps/api/window';
	import { open as openDialog } from '@tauri-apps/plugin-dialog';
	import Popup from '../Popup.svelte';
	import { scrollFade } from '../scrollFade';
	import { files } from '../files';
	import { api, idle, songs, matches, formatTime, type Track, type Status, type Station, type Tab } from './music';

	let {
		tab = $bindable('folder'),
		query = $bindable(''),
		mini,
		chosen = $bindable(false),
		toast,
		shortcuts,
	}: {
		tab: Tab;
		query: string;
		/** a tiny window: the mini player */
		mini: boolean;
		/** MINI (M): the mini player in the window as it is, not made smaller */
		chosen: boolean;
		toast: (text: string) => void;
		/** ReFile's own keys, for INFO */
		shortcuts: string[][];
	} = $props();

	let status: Status = $state(idle);
	let allTracks: Track[] = $state([]);
	let loaded = $state(false);
	let folder: string | null = $state(null);
	let scanning: { done: number; total: number } | null = $state(null);
	let ti = $state(0);
	let trackList: HTMLDivElement | undefined = $state();

	let q = $derived(query.trim().toLowerCase());
	let tracks: Track[] = $derived(songs(q ? allTracks.filter(t => matches(t, q)) : allTracks));
	let track: Track | undefined = $derived(tracks[ti]);
	let progress = $derived(status.track && status.track.durationMs ? Math.min(1, status.positionMs / status.track.durationMs) : 0);

	// MINI (M): the window keeps its size; out of a window made tiny by hand, it grows back to the full one
	const FULL = { width: 1440, height: 900 };
	export async function setMini(on: boolean) {
		chosen = on;
		if (!on && (window.innerWidth < 520 || window.innerHeight < 420)) await getCurrentWindow().setSize(new LogicalSize(FULL.width, FULL.height));
	}

	async function loadLibrary() {
		[allTracks, folder] = await Promise.all([api.tracks(), api.musicFolder()]);
		loaded = true;
		ti = Math.min(ti, Math.max(tracks.length - 1, 0));
	}

	async function refreshStatus() {
		status = await api.status();
	}

	async function playTracks(list: Track[], start = 0) {
		if (!list.length) return;
		await api.play(list.map(t => t.id), start);
		await refreshStatus();
	}

	/** FOLDER: the folder's songs (by their files), from `start` */
	export async function playFiles(paths: string[], start: number) {
		await api.playFiles(paths, start);
		await refreshStatus();
	}

	export const togglePlay = () => api.togglePlay().then(refreshStatus);
	const previous = () => api.previous().then(refreshStatus);
	const next = () => api.next().then(refreshStatus);

	async function toggleShuffle() {
		await api.setShuffle(!status.shuffle);
		await refreshStatus();
		toast(status.shuffle ? 'SHUF' : 'ORDER');
	}

	async function cycleRepeat() {
		const repeat = await api.cycleRepeat();
		await refreshStatus();
		toast({ all: 'REPT', one: 'ONE', off: 'ONCE' }[repeat]);
	}

	function seekTo(e: MouseEvent) {
		const t = status.track;
		if (!t) return;
		const bar = (e.currentTarget as HTMLElement).getBoundingClientRect();
		const fraction = Math.min(1, Math.max(0, (e.clientX - bar.left) / bar.width));
		api.seek(fraction * t.durationMs).then(refreshStatus);
	}

	// ── radio: genres on the left, their stations on the right ──

	const FAVORITES = 'Favorites';
	let genres: string[] = $state([]);
	let favorites: Station[] = $state([]);
	let gi = $state(0);
	let si = $state(0);
	/** which column the arrows move in */
	let side = $state<'genres' | 'stations'>('genres');
	let byGenre: Record<string, Station[]> = $state({});
	let found: Station[] = $state([]);
	let radioLoading = $state(false);
	let radioError = $state('');
	let genreList: HTMLDivElement | undefined = $state();
	let stationList: HTMLDivElement | undefined = $state();

	let genreNames = $derived(favorites.length ? [FAVORITES, ...genres] : genres);
	let genre = $derived(genreNames[gi] ?? '');
	let stations: Station[] = $derived(q ? found : genre === FAVORITES ? favorites : (byGenre[genre] ?? []));
	let station: Station | undefined = $derived(stations[si]);
	let kept = $derived(new Set(favorites.map(s => s.uuid)));

	export async function setTab(next: Tab) {
		if (tab === next) return;
		tab = next;
		query = '';
		if (next === 'radio' && !genres.length) {
			[genres, favorites] = await Promise.all([api.radioGenres(), api.radioFavorites()]);
			gi = 0;
			await loadGenre();
		}
	}

	// the radio tab kept from before (App.svelte): its genres loaded
	onMount(() => {
		if (tab === 'radio') {
			tab = 'folder';
			setTab('radio');
		}
	});

	async function loadGenre() {
		si = 0;
		const name = genre;
		if (!name || name === FAVORITES || byGenre[name]) return;
		radioLoading = true;
		radioError = '';
		try {
			byGenre[name] = await api.radioStations(name);
		} catch (e) {
			radioError = String(e);
		} finally {
			radioLoading = false;
		}
	}

	// the search, in the radio: station names, asked a moment after the typing stops
	let searchTimer: ReturnType<typeof setTimeout> | null = null;
	$effect(() => {
		const text = q;
		if (tab !== 'radio') return;
		if (searchTimer) clearTimeout(searchTimer);
		if (!text) return void (found = []);
		searchTimer = setTimeout(async () => {
			radioLoading = true;
			radioError = '';
			try {
				found = await api.radioSearch(text);
				si = 0;
				side = 'stations';
			} catch (e) {
				radioError = String(e);
			} finally {
				radioLoading = false;
			}
		}, 400);
	});

	async function playStation(index = si) {
		const s = stations[index];
		if (!s) return;
		si = index;
		await api.playStation(s, stations);
		await refreshStatus();
	}

	async function toggleFavorite(s: Station | undefined = station) {
		if (!s) return;
		const on = !kept.has(s.uuid);
		await api.setRadioFavorite(s, on);
		const wasFavorites = genre === FAVORITES;
		favorites = await api.radioFavorites();
		// the left column may have gained or lost Favorites: stay on the same genre
		if (!wasFavorites) gi = Math.max(0, genreNames.indexOf(genre));
		else if (!favorites.length) gi = 0;
		toast(on ? 'KEPT' : 'LET GO');
	}

	async function moveRadio(delta: number) {
		if (side === 'genres' && !q) {
			if (!genreNames.length) return;
			gi = (gi + delta + genreNames.length) % genreNames.length;
			await loadGenre();
			await tick();
			genreList?.querySelector('.row.active')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
		} else {
			if (!stations.length) return;
			si = (si + delta + stations.length) % stations.length;
			await tick();
			stationList?.querySelector('.row.active')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
		}
	}

	async function moveSong(delta: number) {
		if (!tracks.length) return;
		ti = (ti + delta + tracks.length) % tracks.length;
		await tick();
		trackList?.querySelector('.row.active')?.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
	}

	// ── popups ──

	let popup = $state<'none' | 'actions' | 'queue' | 'info'>('none');
	let target: { track: Track; index: number } | null = $state(null);
	let selectedAction = $state(0);
	let upcoming: Track[] = $state([]);

	type Action = { label: string; run: () => unknown };
	let actions: Action[] = $derived.by(() => {
		const t = target;
		if (!t) return [];
		const add = async (fn: (ids: number[]) => Promise<void>, msg: string) => {
			await fn([t.track.id]);
			closePopup();
			toast(msg);
		};
		return [
			{ label: 'Play', run: () => { closePopup(); playTracks(tracks, t.index); } },
			{ label: 'Play next', run: () => add(api.playNext, 'NEXT') },
			{ label: 'Add to queue', run: () => add(api.addToQueue, 'QUEUED') },
			{ label: 'Show in Finder', run: () => { closePopup(); files.reveal(t.track.path); } },
		];
	});

	function openActions(index = ti) {
		const t = tracks[index];
		if (!t) return;
		target = { track: t, index };
		selectedAction = 0;
		popup = 'actions';
	}

	async function openQueue() {
		upcoming = await api.upcoming();
		popup = 'queue';
	}

	export function openInfo() {
		popup = 'info';
	}

	function closePopup() {
		popup = 'none';
	}

	async function chooseFolder() {
		const picked = await openDialog({ directory: true, defaultPath: folder ?? undefined });
		if (typeof picked === 'string') {
			await api.setMusicFolder(picked);
			folder = picked;
			closePopup();
		}
	}

	// ── keys: App.svelte asks first; true when taken ──

	export function key(e: KeyboardEvent, typing: boolean): boolean {
		const mod = e.metaKey || e.ctrlKey || e.altKey;
		if (popup !== 'none') {
			if (e.key === 'Escape') {
				closePopup();
			} else if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && popup === 'actions') {
				const d = e.key === 'ArrowDown' ? 1 : -1;
				selectedAction = (selectedAction + d + actions.length) % actions.length;
			} else if (e.key === 'Enter') {
				if (popup === 'actions') actions[selectedAction]?.run();
				else closePopup();
			} else {
				return true;
			}
			e.preventDefault();
			return true;
		}
		if (mini) {
			if (e.key === ' ') togglePlay();
			else if (!mod && e.code === 'KeyM') setMini(false);
			else return false;
			e.preventDefault();
			return true;
		}
		if (typing) {
			// the search: the arrows and Enter go to the songs or the stations
			if (tab === 'radio' && (e.key === 'ArrowDown' || e.key === 'ArrowUp' || e.key === 'Enter')) {
				side = 'stations';
				if (e.key === 'Enter') playStation();
				else moveRadio(e.key === 'ArrowDown' ? 1 : -1);
			} else if (tab === 'songs' && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
				moveSong(e.key === 'ArrowDown' ? 1 : -1);
			} else if (tab === 'songs' && e.key === 'Enter') {
				playTracks(tracks, ti);
			} else {
				return false;
			}
			e.preventDefault();
			return true;
		}
		if (mod) return false;
		if (e.key === '1' || e.key === '2' || e.key === '3') {
			setTab((['folder', 'songs', 'radio'] as Tab[])[Number(e.key) - 1]);
		} else if (e.key === ' ') {
			togglePlay();
		} else if (e.code === 'KeyS') {
			toggleShuffle();
		} else if (e.code === 'KeyR') {
			cycleRepeat();
		} else if (e.code === 'KeyQ') {
			openQueue();
		} else if (e.code === 'KeyM') {
			setMini(true);
		} else if (e.code === 'KeyI') {
			openInfo();
		} else if (tab === 'radio') {
			if (e.key === 'ArrowDown' || e.key === 'ArrowUp') moveRadio(e.key === 'ArrowDown' ? 1 : -1);
			else if (e.key === 'ArrowRight') side = 'stations';
			else if (e.key === 'ArrowLeft' && !q) side = 'genres';
			else if (e.key === 'Enter') side === 'genres' && !q ? (side = 'stations') : playStation();
			else if (e.code === 'KeyK') toggleFavorite();
			else return false;
		} else if (tab === 'songs') {
			if (e.key === 'ArrowDown' || e.key === 'ArrowUp') moveSong(e.key === 'ArrowDown' ? 1 : -1);
			else if (e.key === 'Enter') playTracks(tracks, ti);
			else if (e.code === 'KeyE') openActions();
			else return false;
		} else {
			return false;
		}
		e.preventDefault();
		return true;
	}

	onMount(() => {
		loadLibrary().then(() => api.rescan().catch(() => {}));
		refreshStatus();
		const timer = setInterval(refreshStatus, 400);
		const unlisten = [
			listen<Status>('player', e => (status = e.payload)),
			listen<{ done?: number; total?: number; finished: boolean }>('scan', e => {
				if (e.payload.finished) {
					scanning = null;
					loadLibrary();
				} else {
					scanning = { done: e.payload.done ?? 0, total: e.payload.total ?? 0 };
				}
			}),
		];
		return () => {
			clearInterval(timer);
			unlisten.forEach(p => p.then(fn => fn()));
		};
	});

	const playKeys = [
		['1 / 2 / 3', 'Folder / songs / radio'],
		['Space', 'Play / pause'],
		['⏮ / ⏭', 'Previous / next song (the Mac\'s media keys)'],
		['Enter', 'Play (a video: here)'],
		['← →', 'Genres / stations (radio)'],
		['K', 'Keep a station'],
		['S / R', 'Shuffle / repeat'],
		['Q', 'Up next'],
		['E / right click', 'Actions'],
		['M', 'Mini player'],
	];
</script>

{#if mini}
	<!-- mini player: the song in the middle, the artist below, the controls under it -->
	<main class="mini fade-in">
		{#if status.error}
			<p class="mini-title error">{status.error}</p>
		{:else if status.station}
			<p class="mini-title">{status.onAir ?? status.station.name}</p>
			<p class="mini-artist">{status.onAir ? status.station.name : status.station.country}</p>
		{:else if status.track}
			<p class="mini-title">{status.track.title}</p>
			<p class="mini-artist">{status.track.artist || status.track.albumArtist}</p>
		{:else}
			<p class="mini-title idle">Nothing playing.</p>
		{/if}
		{#if !status.station}
			<div class="progress-row mini-progress">
				<span class="clock">{formatTime(status.positionMs)}</span>
				<button class="bar" onclick={seekTo} aria-label="Seek" disabled={!status.track}>
					<span class="bar-line"></span>
					<span class="bar-fill" style="width: {progress * 100}%"></span>
				</button>
				<span class="clock">{formatTime(status.track?.durationMs ?? 0)}</span>
			</div>
		{/if}
		<div class="mini-controls">
			<button class="mini-btn arrow" onclick={previous} title="Previous (⏮)" aria-label="Previous">&lt;</button>
			<button class="play" onclick={togglePlay} title="Play / pause (Space)">
				<span class="ink-mark">{status.playing ? 'STOP' : 'PLAY'}</span>
			</button>
			<button class="mini-btn arrow" onclick={next} title="Next (⏭)" aria-label="Next">&gt;</button>
		</div>
	</main>
{:else}
	<!-- no tabs: 1 / 2 / 3 (and SONG / LIVE in PLAY's own window) choose the folder, the songs, the radio -->

	{#if tab === 'radio'}
		<div class="radio">
			<div class="genres list" class:dim={!!q} bind:this={genreList} use:scrollFade>
				{#each genreNames as name, i (name)}
					<button class="row genre-row" class:active={i === gi} onclick={() => { gi = i; side = 'genres'; query = ''; loadGenre(); }}>
						<span class="name" class:ink-mark={i === gi && side === 'genres' && !q} class:chosen={i === gi}>{name}</span>
					</button>
				{/each}
			</div>
			<div class="stations list" bind:this={stationList} use:scrollFade>
				{#each stations as s, i (s.uuid)}
					<button
						class="row station-row"
						class:active={i === si}
						onclick={() => { si = i; side = 'stations'; }}
						ondblclick={() => playStation(i)}
						oncontextmenu={() => { si = i; toggleFavorite(s); }}
					>
						<span class="cell-title">
							{#if status.station?.uuid === s.uuid}<span class="dot"></span>{/if}
							<span class="name" class:ink-mark={i === si && side === 'stations'}>{s.name}</span>
							{#if kept.has(s.uuid) && genre !== FAVORITES}<span class="kept" title="Kept (K)">◆</span>{/if}
						</span>
						<span class="cell">{s.country}</span>
						<span class="cell kind">{s.codec} {s.bitrate || ''}</span>
					</button>
				{:else}
					<p class="empty">{radioLoading ? 'Tuning in…' : radioError || (q ? 'Nothing found.' : genre === FAVORITES ? 'No stations kept yet.' : 'No stations.')}</p>
				{/each}
			</div>
		</div>
	{:else if tab === 'songs'}
		{#if loaded && allTracks.length === 0 && !scanning}
			<div class="welcome">
				<p>No music in <span class="ink-mark">{folder ? folder.split('/').pop() : 'your folder'}</span> yet.</p>
				<button class="pop-btn" onclick={chooseFolder}>CHOOSE FOLDER</button>
			</div>
		{:else}
			<div class="songs list" bind:this={trackList} use:scrollFade>
				{#each tracks as t, i (t.id)}
					<button
						class="row song-row"
						class:active={i === ti}
						onclick={() => (ti = i)}
						ondblclick={() => playTracks(tracks, i)}
						oncontextmenu={() => { ti = i; openActions(i); }}
					>
						<span class="cell-title">
							{#if status.track?.id === t.id}<span class="dot"></span>{/if}
							<span class="name" class:ink-mark={i === ti}>{t.title}</span>
						</span>
						<span class="cell">{t.artist || t.albumArtist}</span>
						<span class="cell time">{formatTime(t.durationMs)}</span>
					</button>
				{:else}
					<p class="empty">{q ? 'Nothing found.' : 'No songs yet.'}</p>
				{/each}
			</div>
		{/if}
	{/if}

	<!-- the player -->
	<footer class="player">
		{#if status.error}
			<p class="now error">{status.error}</p>
		{:else if status.station}
			<p class="now">
				{#if status.onAir}<span class="now-title">{status.onAir}</span><span class="now-artist">{` - ${status.station.name}`}</span>
				{:else}<span class="now-title">{status.station.name}</span>{/if}
			</p>
		{:else if status.track}
			<p class="now"><span class="now-title">{status.track.title}</span><span class="now-artist">{` - ${status.track.artist || status.track.albumArtist}`}</span></p>
		{:else}
			<p class="now idle">Nothing playing.</p>
		{/if}
		{#if !status.station}
			<div class="progress-row">
				<span class="clock">{formatTime(status.positionMs)}</span>
				<button class="bar" onclick={seekTo} aria-label="Seek" disabled={!status.track}>
					<span class="bar-line"></span>
					<span class="bar-fill" style="width: {progress * 100}%"></span>
				</button>
				<span class="clock">{formatTime(status.track?.durationMs ?? 0)}</span>
			</div>
		{/if}
		<!-- the previous / next song or station: < and > on either side of it -->
		<div class="player-controls">
			<button class="mini-btn arrow" onclick={previous} title="Previous (⏮)" aria-label="Previous">&lt;</button>
			<button class="play" onclick={togglePlay} title="Play / pause (Space)">
				<span class="ink-mark">{status.playing ? 'STOP' : 'PLAY'}</span>
			</button>
			<button class="mini-btn arrow" onclick={next} title="Next (⏭)" aria-label="Next">&gt;</button>
		</div>
	</footer>
{/if}

{#if scanning}
	<div class="toast"><span>SCAN</span></div>
{/if}

{#if popup === 'actions' && target}
	<Popup onclose={closePopup}>
		<p class="pop-text">{target.track.title}</p>
		<div class="pop-divider"></div>
		<div class="menu">
			{#each actions as action, i}
				<button class="menu-item" onclick={() => action.run()} onmouseenter={() => (selectedAction = i)}>
					<span class:ink-mark={i === selectedAction}>{tx(action.label)}</span>
				</button>
			{/each}
		</div>
	</Popup>
{:else if popup === 'queue'}
	<Popup onclose={closePopup}>
		<p class="pop-heading">{tx('UP NEXT')}</p>
		<div class="pop-divider"></div>
		{#if upcoming.length}
			<div class="queue" use:scrollFade>
				{#each upcoming as t, i (`${t.id}-${i}`)}
					<p class="queue-row"><span class="no">{i + 1}</span><span class="name">{t.title}</span><span class="artist">{t.artist}</span></p>
				{/each}
			</div>
		{:else}
			<p class="pop-note">{tx('Nothing after this song.')}</p>
		{/if}
	</Popup>
{:else if popup === 'info'}
	<Popup onclose={closePopup}>
		<p class="pop-heading">RE:FILE · PLAY</p>
		<div class="pop-divider"></div>
		<p class="pop-text">{tx(allTracks.length === 1 ? '{n} song' : '{n} songs', { n: allTracks.length })}</p>
		<p class="pop-note">{folder ?? tx('No folder chosen')}</p>
		<div class="pop-actions">
			<button class="pop-btn" onclick={chooseFolder}>{tx('FOLDER')}</button>
			<button class="pop-btn" onclick={() => { api.rescan(); closePopup(); }}>{tx('RESCAN')}</button>
		</div>
		<div class="pop-divider"></div>
		<div class="shortcuts">
			{#each [...playKeys, ...shortcuts] as [k, desc]}
				<span class="key">{tx(k)}</span><span class="desc">{tx(desc)}</span>
			{/each}
		</div>
		<div class="pop-divider"></div>
		<p class="pop-footer">MP3 · AAC · ALAC · FLAC · WAV · AIFF · OGG<br />MP4 · MOV · WEBM</p>
	</Popup>
{/if}

<style>

	/* ── songs and the radio: between the search and the player ── */
	.songs,
	.radio {
		position: fixed;
		top: calc(6.25% + 40px);
		bottom: calc(6.25% + 112px);
		left: calc(6.25% + 96px);
		right: calc(6.25% + 96px);
	}

	.radio {
		display: grid;
		grid-template-columns: 200px minmax(0, 1fr);
		column-gap: 48px;
	}

	.list {
		overflow-y: auto;
		overflow-x: hidden;
		display: flex;
		flex-direction: column;
		gap: 16px;
		/* room for the ink stroke of the selected row */
		padding: 0.4em 0.6em;
	}

	.genres .name { opacity: 0.6; }
	.genres .name.chosen { opacity: 1; }
	.genres.dim { opacity: 0.35; }

	.station-row {
		display: grid;
		grid-template-columns: minmax(0, 2fr) minmax(0, 1fr) 80px;
		column-gap: 24px;
		width: 100%;
	}

	.kind { font-size: 13px; opacity: 0.45; text-align: right; }
	.kept { font-size: 9px; margin-left: 8px; opacity: 0.55; }

	.row {
		display: flex;
		align-items: baseline;
		gap: 14px;
		min-width: 0;
		flex-shrink: 0;
		background: transparent;
		border: none;
		padding: 0;
		text-align: left;
		font-family: 'Kurale', serif;
		font-size: 16px;
		line-height: 1.2;
		cursor: pointer;
		scroll-margin: 56px 0;
	}

	.name {
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		min-width: 0;
	}

	.time,
	.clock {
		font-size: 15px;
		opacity: 0.6;
		font-variant-numeric: tabular-nums;
		flex-shrink: 0;
	}

	/* the song that is playing */
	.dot {
		display: inline-block;
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--text);
		margin-right: 4px;
		vertical-align: middle;
	}

	.song-row {
		display: grid;
		grid-template-columns: minmax(0, 2fr) minmax(0, 1fr) 60px;
		column-gap: 24px;
		width: 100%;
	}

	.cell-title { display: flex; align-items: baseline; min-width: 0; }

	.cell {
		font-size: 16px;
		opacity: 0.7;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.cell.time { text-align: right; }

	.empty {
		font-family: 'Kurale', serif;
		font-size: 16px;
		opacity: 0.45;
	}

	.welcome {
		position: fixed;
		top: 45%;
		left: 50%;
		transform: translate(-50%, -50%);
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 2rem;
		font-family: 'Kurale', serif;
		font-size: 24px;
		text-align: center;
	}

	.welcome .pop-btn {
		background: transparent;
		border: 2px solid var(--line);
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 16px;
		letter-spacing: 0.2em;
		padding: 0.5rem 1.4rem;
		cursor: pointer;
		transition: background 200ms ease, color 200ms ease;
	}

	.welcome .pop-btn:hover { background: var(--line); color: var(--bg); }

	/* ── the player ── */
	.player {
		position: fixed;
		left: 50%;
		bottom: calc(6.25% - 14px);
		transform: translateX(-50%);
		width: min(560px, calc(100% - 2 * (6.25% + 100px)));
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 10px;
		z-index: 5;
	}

	.now {
		max-width: 100%;
		font-family: 'Kurale', serif;
		font-size: 24px;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.now-artist { opacity: 0.6; }
	.now.idle { opacity: 0.45; }
	.now.error { font-size: 15px; color: var(--error); }

	.progress-row {
		width: 100%;
		display: flex;
		align-items: center;
		gap: 14px;
	}

	.bar {
		position: relative;
		flex: 1;
		height: 18px;
		background: transparent;
		border: none;
		padding: 0;
		cursor: pointer;
	}

	.bar-line,
	.bar-fill {
		position: absolute;
		left: 0;
		top: 50%;
		height: 2px;
		transform: translateY(-50%);
		background: var(--line);
	}

	.bar-line { right: 0; opacity: 0.25; }
	.bar-fill { transition: width 400ms linear; }

	.play {
		background: transparent;
		border: none;
		padding: 0.3em 0.6em;
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 15px;
		letter-spacing: 0.4em;
		cursor: pointer;
	}

	.play .ink-mark { padding-right: calc(0.45em - 0.4em); }

	/* ── mini player ── */
	.mini {
		position: fixed;
		inset: 0;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 10px;
		padding: 36px 44px 24px;
	}

	.mini-title {
		max-width: 100%;
		font-family: 'Kurale', serif;
		font-size: 24px;
		line-height: 1.25;
		text-align: center;
		overflow-wrap: anywhere;
		display: -webkit-box;
		-webkit-line-clamp: 2;
		line-clamp: 2;
		-webkit-box-orient: vertical;
		overflow: hidden;
	}

	.mini-title.idle { opacity: 0.45; }
	.mini-title.error { font-size: 15px; color: var(--error); }

	.mini-artist {
		max-width: 100%;
		font-family: 'Kurale', serif;
		font-size: 16px;
		opacity: 0.6;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.mini-progress { margin-top: 14px; max-width: 380px; }

	.mini-controls {
		display: flex;
		align-items: center;
		gap: 1.6rem;
		margin-top: 4px;
	}

	.mini-btn {
		background: transparent;
		border: none;
		padding: 0.3em 0.4em;
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 20px;
		line-height: 1;
		opacity: 0.6;
		cursor: pointer;
	}

	.mini-btn:hover { opacity: 1; }

	.player-controls {
		display: flex;
		align-items: center;
		justify-content: center;
		gap: 1.6rem;
	}

	/* ── a small window (not yet the mini player's): the same, closer to the edges ── */
	@media (max-width: 759px), (max-height: 559px) {
		.songs,
		.radio {
			top: 52px;
			bottom: 128px;
			left: 40px;
			right: 40px;
		}

		.radio { grid-template-columns: minmax(0, 2fr) minmax(0, 3fr); column-gap: 20px; }
		.station-row { grid-template-columns: minmax(0, 1fr) 70px; }
		.station-row .kind { display: none; }
		.song-row { grid-template-columns: minmax(0, 1fr) 56px; }
		.song-row .cell:not(.time) { display: none; }

		.player {
			bottom: 14px;
			width: calc(100% - 80px);
			gap: 6px;
		}

		.now { font-size: 18px; }
	}
	/* the words as large as in a small window, whatever its size (as in all the Re apps) */
	.now {
		font-size: 18px;
	}

	/* ── SCAN, as ReFile's toast ── */
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
		z-index: 79;
	}

	.toast span {
		writing-mode: vertical-rl;
		text-orientation: upright;
		letter-spacing: 0.6em;
		font-size: 16px;
		line-height: 32px;
	}

	/* ── popups ── */
	.menu {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 16px;
		padding: 0.3em 0.5em;
		max-height: 50vh;
		overflow-y: auto;
	}

	.menu-item {
		background: transparent;
		border: none;
		padding: 0;
		font-family: 'Kurale', serif;
		font-size: 16px;
		line-height: 1.2;
		text-align: left;
		cursor: pointer;
	}

	.queue {
		width: 100%;
		max-height: 50vh;
		overflow-y: auto;
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.queue-row {
		display: flex;
		align-items: baseline;
		gap: 12px;
		font-family: 'Kurale', serif;
		font-size: 16px;
		min-width: 0;
	}

	.queue-row .no { width: 1.8em; flex-shrink: 0; text-align: right; font-size: 14px; opacity: 0.55; }

	.queue-row .artist {
		font-family: 'Noto Sans JP', sans-serif;
		font-size: 12px;
		letter-spacing: 0.06em;
		opacity: 0.55;
		white-space: nowrap;
		margin-left: auto;
		padding-left: 12px;
	}

	.pop-note {
		font-family: 'Kurale', serif;
		font-size: 15px;
		opacity: 0.65;
		text-align: center;
		overflow-wrap: anywhere;
	}

	.shortcuts {
		display: grid;
		grid-template-columns: auto auto;
		gap: 8px 24px;
		font-size: 13px;
	}

	.shortcuts .key { font-family: 'Noto Sans JP', sans-serif; letter-spacing: 0.1em; text-align: right; opacity: 0.85; }
	.shortcuts .desc { font-family: 'Kurale', serif; opacity: 0.7; }

	.pop-footer {
		font-family: 'Kurale', serif;
		font-size: 13px;
		letter-spacing: 0.15em;
		opacity: 0.55;
	}
</style>
