// Unicode normalization (NFD/NFC) from nf.json, used by make.ts.
// The contract mirrors this: decompose => canonical reorder => compose.
// https://unicode.org/reports/tr15/

export type NFJSON = {
	ranks: number[][]; // cps grouped by increasing non-zero combining class
	exclusions: number[];
	decomp: [number, number[]][];
	qc: number[]; // NFC_QC != Yes
};

// algorithmic hangul
export const S0 = 0xac00;
export const L0 = 0x1100;
export const V0 = 0x1161;
export const T0 = 0x11a7;
export const L_COUNT = 19;
export const V_COUNT = 21;
export const T_COUNT = 28;
export const N_COUNT = V_COUNT * T_COUNT;
export const S_COUNT = L_COUNT * N_COUNT;

export const isHangul = (cp: number) => cp >= S0 && cp < S0 + S_COUNT;

export class NF {
	readonly rank = new Map<number, number>();
	readonly decomp = new Map<number, number[]>();
	readonly comp = new Map<number, number>(); // pairKey(a, b) => composed
	readonly qc: Set<number>;

	constructor(json: NFJSON) {
		json.ranks.forEach((v, i) => {
			for (const cp of v) this.rank.set(cp, i + 1);
		});
		const exclusions = new Set(json.exclusions);
		for (const [cp, v] of json.decomp) {
			this.decomp.set(cp, v);
			if (v.length === 2 && !exclusions.has(cp)) this.comp.set(pairKey(v[0]!, v[1]!), cp);
		}
		this.qc = new Set(json.qc);
	}

	/** full canonical decomposition of one cp (no reordering) */
	decompose(cp: number, out: number[] = []): number[] {
		if (isHangul(cp)) {
			const s = cp - S0;
			out.push(L0 + Math.floor(s / N_COUNT), V0 + Math.floor((s % N_COUNT) / T_COUNT));
			if (s % T_COUNT) out.push(T0 + (s % T_COUNT));
		} else {
			const v = this.decomp.get(cp);
			if (v) for (const x of v) this.decompose(x, out);
			else out.push(cp);
		}
		return out;
	}

	composePair(a: number, b: number): number {
		if (a >= L0 && a < L0 + L_COUNT && b >= V0 && b < V0 + V_COUNT) {
			return S0 + (a - L0) * N_COUNT + (b - V0) * T_COUNT;
		} else if (isHangul(a) && b > T0 && b < T0 + T_COUNT && (a - S0) % T_COUNT === 0) {
			return a + (b - T0);
		}
		return this.comp.get(pairKey(a, b)) ?? -1;
	}

	nfd(cps: number[]): number[] {
		const v: number[] = [];
		for (const cp of cps) this.decompose(cp, v);
		// stable insertion sort of each run of non-starters
		for (let i = 1; i < v.length; i++) {
			const r = this.rank.get(v[i]!) ?? 0;
			if (!r) continue;
			let j = i;
			while (j > 0 && (this.rank.get(v[j - 1]!) ?? 0) > r) {
				[v[j - 1], v[j]] = [v[j]!, v[j - 1]!];
				j--;
			}
		}
		return v;
	}

	nfc(cps: number[]): number[] {
		const out: number[] = [];
		let starter = -1;
		let prev = -1; // rank of the last char after the starter (-1 = adjacent)
		for (const cp of this.nfd(cps)) {
			const r = this.rank.get(cp) ?? 0;
			if (starter >= 0 && prev < r) {
				const c = this.composePair(out[starter]!, cp);
				if (c >= 0) {
					out[starter] = c;
					continue;
				}
			}
			if (r) {
				prev = r;
			} else {
				starter = out.length;
				prev = -1;
			}
			out.push(cp);
		}
		return out;
	}
}

export const pairKey = (a: number, b: number) => a * 0x1000000 + b;
