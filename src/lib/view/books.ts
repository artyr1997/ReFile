// VIEW (what ReBook was): books read where they lie. The place each was left at is kept here, in the
// window's storage, by the book's path; comics' pages come from Rust over refile:// (src-tauri/src/books.rs).
import { invoke } from '@tauri-apps/api/core';

export type Format = 'pdf' | 'epub' | 'cbz' | 'cbr';

export interface Book {
	path: string;
	/** the file's name, without its extension */
	title: string;
	format: Format;
}

export interface PageSize {
	width: number;
	height: number;
}

/** Where a book was left: a page index (PDF, comics) or an EPUB CFI; how far, 0…1; manga (right to left). */
export interface Place {
	position: string | null;
	progress: number;
	rtl: boolean;
}

const key = (path: string) => `book:${path}`;

export function placeOf(path: string): Place {
	try {
		const saved = JSON.parse(localStorage.getItem(key(path)) ?? '');
		if (saved && typeof saved === 'object') return { position: saved.position ?? null, progress: saved.progress ?? 0, rtl: !!saved.rtl };
	} catch {}
	return { position: null, progress: 0, rtl: false };
}

export function keepPlace(path: string, change: Partial<Place>) {
	try {
		localStorage.setItem(key(path), JSON.stringify({ ...placeOf(path), ...change }));
	} catch {}
}

export const comicPages = (path: string) => invoke<PageSize[]>('comic_pages', { path });
export const pageUrl = (path: string, index: number) => `refile://localhost/page/${index}?${encodeURIComponent(path)}`;

export const isComic = (f: Format) => f === 'cbz' || f === 'cbr';

const isPortrait = (p: PageSize) => p.height > p.width;

/**
 * Groups pages into what is shown at once:
 * - portrait pages go side by side, two per screen
 * - a landscape page (wider than tall) gets the whole screen
 * - the cover stands alone, like the front of a printed comic
 * - a portrait page left without a portrait partner stands alone
 * - in a small window (`single`) every page stands alone
 */
export function buildSpreads(pages: PageSize[], single = false): number[][] {
	const spreads: number[][] = [];
	let i = 0;
	while (i < pages.length) {
		if (!single && i > 0 && isPortrait(pages[i]) && i + 1 < pages.length && isPortrait(pages[i + 1])) {
			spreads.push([i, i + 1]);
			i += 2;
		} else {
			spreads.push([i]);
			i += 1;
		}
	}
	return spreads;
}

/** The spread that contains page `index`. */
export function spreadOf(spreads: number[][], index: number): number {
	const found = spreads.findIndex(s => s.includes(index));
	return found >= 0 ? found : 0;
}

/** Display sizes (CSS px) for the pages of one spread, fitted into `box` side by side. */
export function fitSpread(pages: PageSize[], box: { width: number; height: number }): PageSize[] {
	const ratios = pages.map(p => p.width / p.height);
	const totalRatio = ratios.reduce((a, b) => a + b, 0);
	const height = Math.min(box.height, box.width / totalRatio);
	return ratios.map(r => ({ width: Math.floor(height * r), height: Math.floor(height) }));
}

/** "12 / 180" or "12–13 / 180" */
export function pageLabel(spread: number[] | undefined, total: number): string {
	if (!spread || total === 0) return '';
	const first = spread[0] + 1;
	const last = spread[spread.length - 1] + 1;
	return `${first === last ? first : `${first}–${last}`} / ${total}`;
}
