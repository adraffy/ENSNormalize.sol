import keccak from '@adraffy/keccak/256';

export function assert(ok: unknown, msg: string): asserts ok {
	if (!ok) throw new Error(`assert: ${msg}`);
}

export const hex = (cp: number) => cp.toString(16).toUpperCase().padStart(4, '0');

export const keccak256 = (v: Uint8Array) => `0x${Buffer.from(keccak(v)).toString('hex')}`;

export function concat(v: Uint8Array[]): Uint8Array {
	const ret = new Uint8Array(v.reduce((a, x) => a + x.length, 0));
	let pos = 0;
	for (const x of v) {
		ret.set(x, pos);
		pos += x.length;
	}
	return ret;
}

/** big-endian byte writer */
export class Bytes {
	private v: number[] = [];
	get length() {
		return this.v.length;
	}
	private uint(x: number, n: number) {
		assert(Number.isInteger(x) && x >= 0 && x < 2 ** (8 * n), `u${8 * n} ${x}`);
		for (let i = n - 1; i >= 0; i--) this.v.push(Math.floor(x / 2 ** (8 * i)) & 0xff);
		return this;
	}
	u8(x: number) {
		return this.uint(x, 1);
	}
	u16(x: number) {
		return this.uint(x, 2);
	}
	u24(x: number) {
		return this.uint(x, 3);
	}
	u32(x: number) {
		return this.uint(x, 4);
	}
	bytes(b: Uint8Array) {
		for (const x of b) this.v.push(x);
		return this;
	}
	toBytes() {
		return Uint8Array.from(this.v);
	}
}
