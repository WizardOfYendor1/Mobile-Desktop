package com.ryanheise.audioservice

// AudioService.instance is package private, so the lookup lives in the
// plugin's package.
object AudioServiceState {
    fun isPlaying(): Boolean = AudioService.instance?.isPlaying() == true
}
