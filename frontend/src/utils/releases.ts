export async function fetchLatestReleaseBody(): Promise<string> {
  const url =
    "https://api.github.com/repos/LiteLDev/LeviLauncher/releases/latest";
  const resp = await fetch(url, {
    method: "GET",
    headers: {
      Accept: "application/vnd.github+json",
    },
    cache: "no-store",
  });
  if (!resp.ok) return "";
  const json = await resp.json();
  const body = String(json?.body || "");
  return body;
}
