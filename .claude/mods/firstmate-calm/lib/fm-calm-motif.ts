// Firstmate's terminal-presentation motif selector.
//
// `config/calm-motif` is intentionally a small shared preference rather than a theme
// engine: `starfleet` selects the Starfleet-style working ship and presentation glyphs,
// while an absent or unrecognized value preserves the nautical default.
export type CalmMotif = "nautical" | "starfleet";

export const CALM_MOTIF_NAUTICAL: CalmMotif = "nautical";
export const CALM_MOTIF_STARFLEET: CalmMotif = "starfleet";

/** Parse the one supported opt-in value without making a malformed preference disruptive. */
export function parseCalmMotif(stored: string | undefined): CalmMotif {
  return stored?.trim() === CALM_MOTIF_STARFLEET
    ? CALM_MOTIF_STARFLEET
    : CALM_MOTIF_NAUTICAL;
}

/** The glyphs used by Firstmate-owned terminal presentation for one motif. */
export function calmMotifGlyphs(motif: CalmMotif): { routine: string; captain: string } {
  return motif === CALM_MOTIF_STARFLEET
    ? { routine: "🛸", captain: "✦" }
    : { routine: "⛵", captain: "⚓" };
}
