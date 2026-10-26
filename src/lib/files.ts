// Bridge to the Rust side (src-tauri/src/lib.rs) plus formatting helpers.
import { invoke } from '@tauri-apps/api/core';

export interface Entry {
	name: string;
	path: string;
	/** folder you can step into (app bundles count as files) */
	isDir: boolean;
	/** bytes; null for folders */
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
	list: (path: string) => invoke<Entry[]>('list_dir', { path }),
	info: (path: string) => invoke<Info>('item_info', { path }),
	createFolder: (parent: string, name: string) => invoke<string>('create_folder', { parent, name }),
	rename: (path: string, name: string) => invoke<string>('rename_item', { path, name }),
	duplicate: (path: string) => invoke<string>('duplicate_item', { path }),
	reveal: (path: string) => invoke<void>('reveal_in_finder', { path }),
	moveToTrash: (path: string) => invoke<void>('move_to_trash', { path }),
	open: (path: string) => invoke<void>('open_path', { path }),
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
