// Bridge to the Rust side (src-tauri/src/lib.rs) plus formatting helpers.
import { invoke } from '@tauri-apps/api/core';

export interface Entry {
	name: string;
	path: string;
	/** folder you can step into (app bundles count as files) */
	isDir: boolean;
	/** bytes; null for folders (and app bundles): files.folderSize measures them */
	size: number | null;
	/** ms since epoch */
	modified: number | null;
}

export interface Info {
	name: string;
	path: string;
	kind: string;
	isDir: boolean;
	size: number | null;
	items: number | null;
	created: number | null;
	modified: number | null;
}

export const files = {
	homeDir: () => invoke<string>('home_dir'),
	diskSpace: () => invoke<{ total: number; free: number }>('disk_space'),
	load: () => invoke<{ cpu: number; memory: number }>('load'),
	list: (path: string) => invoke<Entry[]>('list_dir', { path }),
	info: (path: string) => invoke<Info>('item_info', { path }),
	folderSize: (path: string) => invoke<number>('folder_size', { path }),
	createFolder: (parent: string, name: string) => invoke<string>('create_folder', { parent, name }),
	rename: (path: string, name: string) => invoke<string>('rename_item', { path, name }),
	duplicate: (path: string) => invoke<string>('duplicate_item', { path }),
	compress: (path: string) => invoke<string>('compress_item', { path }),
	reveal: (path: string) => invoke<void>('reveal_in_finder', { path }),
	moveToTrash: (path: string) => invoke<void>('move_to_trash', { path }),
	open: (path: string) => invoke<void>('open_path', { path }),
	readFile: (path: string) => invoke<ArrayBuffer>('read_file', { path }),
	readText: (path: string) => invoke<{ text: string; truncated: boolean }>('read_text', { path }),
	writeText: (path: string, text: string) => invoke<void>('write_text', { path, text }),
	openInRePlay: (path: string) => invoke<void>('open_in_replay', { path }),
};

export function parentOf(path: string): string | null {
	if (path === '/') return null;
	const parent = path.replace(/\/+$/, '').replace(/\/[^/]*$/, '');
	return parent || '/';
}

export function nameOf(path: string): string {
	if (path === '/') return 'Macintosh HD';
	return path.replace(/\/+$/, '').split('/').pop() || path;
}

const pad = (n: number) => String(n).padStart(2, '0');

/** 17.02.2025 23.12.03 */
export function formatDate(ms: number | null): string {
	if (ms === null) return '--';
	const d = new Date(ms);
	return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}.${pad(d.getMinutes())}.${pad(d.getSeconds())}`;
}

/** Finder-style decimal sizes: 438 bytes, 3 KB, 1.2 MB */
export function formatSize(bytes: number | null): string {
	if (bytes === null) return '--';
	if (bytes < 1000) return `${bytes} ${bytes === 1 ? 'byte' : 'bytes'}`;
	const units = ['KB', 'MB', 'GB', 'TB'];
	let value = bytes / 1000;
	let unit = 0;
	while (value >= 1000 && unit < units.length - 1) {
		value /= 1000;
		unit++;
	}
	return `${unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}

// ── what opens where: pictures and text in ReFile's viewer, music and videos in RePlay ──

const IMAGES: Record<string, string> = {
	png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp',
	heic: 'image/heic', heif: 'image/heif', avif: 'image/avif', bmp: 'image/bmp', tif: 'image/tiff',
	tiff: 'image/tiff', svg: 'image/svg+xml', ico: 'image/x-icon',
};
// the same as RePlay plays
const AUDIO = ['mp3', 'm4a', 'aac', 'alac', 'flac', 'wav', 'aif', 'aiff', 'ogg', 'opus'];
const VIDEO = ['mp4', 'm4v', 'mov', 'webm'];
const TEXT = [
	'txt', 'md', 'markdown', 'log', 'csv', 'tsv', 'json', 'jsonl', 'yaml', 'yml', 'toml', 'ini', 'conf', 'cfg', 'env',
	'xml', 'html', 'htm', 'css', 'scss', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'svelte', 'vue', 'py', 'rb', 'rs',
	'go', 'swift', 'java', 'kt', 'c', 'h', 'cpp', 'hpp', 'cs', 'php', 'sh', 'zsh', 'bash', 'fish', 'sql', 'lua',
	'gitignore', 'dockerfile', 'makefile', 'srt', 'vtt', 'tex', 'plist', 'jmx', 'itermcolors',
];

function extension(name: string): string {
	const dot = name.lastIndexOf('.');
	return dot > 0 ? name.slice(dot + 1).toLowerCase() : dot === 0 ? name.slice(1).toLowerCase() : '';
}

/** A file with no extension (README, Makefile) is tried as text; ReFile falls back to the Mac if it isn't. */
export function kindOf(name: string): 'image' | 'text' | 'audio' | 'video' | 'other' {
	const ext = extension(name);
	if (ext in IMAGES) return 'image';
	if (AUDIO.includes(ext)) return 'audio';
	if (VIDEO.includes(ext)) return 'video';
	if (TEXT.includes(ext) || ext === '') return 'text';
	return 'other';
}

export function imageType(name: string): string {
	return IMAGES[extension(name)] ?? '';
}
