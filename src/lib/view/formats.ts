// Opening PDF and EPUB files in the UI, and a book's cover for the preview column.
import * as pdfjs from 'pdfjs-dist';
import pdfWorker from 'pdfjs-dist/build/pdf.worker.min.mjs?url';
import ePub from 'epubjs';
import type { Book as EpubBook } from 'epubjs';
import kuraleLatin from '@fontsource/kurale/files/kurale-latin-400-normal.woff2?url';
import kuraleCyrillic from '@fontsource/kurale/files/kurale-cyrillic-400-normal.woff2?url';
import { files } from '../files';
import { comicPages, pageUrl, isComic, type Format } from './books';

pdfjs.GlobalWorkerOptions.workerSrc = pdfWorker;

export async function openPdf(path: string) {
	return pdfjs.getDocument({ data: new Uint8Array(await files.readFile(path)) }).promise;
}

export async function openEpub(path: string): Promise<EpubBook> {
	const book = ePub(await files.readFile(path));
	await book.ready;
	return book;
}

/** Kurale inside EPUB pages (they live in their own iframe, so the app's fonts don't reach them). */
export function epubFontCss(): string {
	const abs = (u: string) => new URL(u, location.href).href;
	return `
		@font-face { font-family: 'Kurale'; font-weight: 400; font-display: swap;
			src: url('${abs(kuraleLatin)}') format('woff2');
			unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD; }
		@font-face { font-family: 'Kurale'; font-weight: 400; font-display: swap;
			src: url('${abs(kuraleCyrillic)}') format('woff2');
			unicode-range: U+0301, U+0400-045F, U+0490-0491, U+04B0-04B1, U+2116; }`;
}

const COVER_WIDTH = 480;

async function pdfCover(path: string): Promise<string> {
	const doc = await openPdf(path);
	try {
		const page = await doc.getPage(1);
		const base = page.getViewport({ scale: 1 });
		const viewport = page.getViewport({ scale: COVER_WIDTH / base.width });
		const canvas = document.createElement('canvas');
		canvas.width = Math.round(viewport.width);
		canvas.height = Math.round(viewport.height);
		const ctx = canvas.getContext('2d')!;
		ctx.fillStyle = '#fff';
		ctx.fillRect(0, 0, canvas.width, canvas.height);
		await page.render({ canvasContext: ctx, viewport }).promise;
		return canvas.toDataURL('image/jpeg', 0.85);
	} finally {
		doc.destroy();
	}
}

async function epubCover(path: string): Promise<string | null> {
	const book = await openEpub(path);
	try {
		const url = await book.coverUrl().catch(() => null);
		if (!url) return null;
		// the cover's blob goes with the book: copied out first
		const blob = await (await fetch(url)).blob();
		return await new Promise(done => {
			const reader = new FileReader();
			reader.onload = () => done(String(reader.result));
			reader.onerror = () => done(null);
			reader.readAsDataURL(blob);
		});
	} finally {
		book.destroy();
	}
}

/** A book's cover as a picture's address (a comic's first page); null when it has none. */
export async function coverOf(path: string, format: Format): Promise<string | null> {
	if (isComic(format)) {
		await comicPages(path);
		return pageUrl(path, 0);
	}
	return format === 'pdf' ? pdfCover(path) : epubCover(path);
}
