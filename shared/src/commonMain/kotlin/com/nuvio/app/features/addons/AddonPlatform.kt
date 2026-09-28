package com.nuvio.app.features.addons

expect object AddonStorage {
    fun loadInstalledAddonUrls(profileId: Int): List<String>
    /// Whether an installed-add-on list was ever stored for [profileId] on this device — an EMPTY
    /// stored list included (unlike `loadInstalledAddonUrls(profileId).isNotEmpty()`). The account
    /// wipe removes the key, so after a sign-out/in this is false again.
    fun hasStoredInstalledAddonUrls(profileId: Int): Boolean
    fun saveInstalledAddonUrls(profileId: Int, urls: List<String>)
    fun loadAddonEnabledStates(profileId: Int): Map<String, Boolean>
    fun saveAddonEnabledStates(profileId: Int, states: Map<String, Boolean>)
}

data class RawHttpResponse(
    val status: Int,
    val statusText: String,
    val url: String,
    val body: String,
    val headers: Map<String, String>,
)

/** Default safety limit for generic and plugin-provided HTTP responses. */
internal const val DefaultRawHttpResponseMaxBytes = 1024 * 1024

expect suspend fun httpGetText(url: String): String

expect suspend fun httpPostJson(url: String, body: String): String

expect suspend fun httpGetTextWithHeaders(
    url: String,
    headers: Map<String, String>,
): String

expect suspend fun httpPostJsonWithHeaders(
    url: String,
    body: String,
    headers: Map<String, String>,
): String

expect suspend fun httpRequestRaw(
    method: String,
    url: String,
    headers: Map<String, String>,
    body: String,
    followRedirects: Boolean = true,
    maxResponseBodyBytes: Int = DefaultRawHttpResponseMaxBytes,
): RawHttpResponse
