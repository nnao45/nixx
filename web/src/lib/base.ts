// import.meta.env.BASE_URL carries no trailing slash for a custom base ("/nixx").
// Normalize once so template strings join correctly: `${base}api/` → "/nixx/api/".
const raw = import.meta.env.BASE_URL;
export const base: string = raw.endsWith("/") ? raw : `${raw}/`;
