;;;; init.lisp --- SAMPLE revl user config.
;;;;
;;;; Copy this file to  ~/.config/revl/init.lisp  — it is loaded (in the REVL
;;;; package) after the desktop layout is restored.  See the revl README
;;;; ("Configuration"); a sibling early-init.lisp loads *before* the restore.
;;;;
;;;; Register a WAV / RIFF structural template for the hex editor.
;;;;
;;;; The whole form is guarded with #+revision-hexdump — a read-time feature test.
;;;; When the hex-editor widget isn't loaded the feature is absent, so the reader
;;;; SKIPS the form (under *read-suppress*, the revision-hexdump: package prefix is
;;;; not an error), and this file stays harmless.

#+revision-hexdump
(pushnew
 '("WAV / RIFF audio"
   (:endian :little) (:magic "RIFF")
   (chunk-id        (:string 4))     ; "RIFF"
   (chunk-size      :u32)            ; file length - 8
   (format          (:string 4))     ; "WAVE"
   (subchunk1-id    (:string 4))     ; "fmt "
   (subchunk1-size  :u32)            ; 16 for PCM
   (audio-format    :u16 :enum ((1 . "PCM") (3 . "IEEE float")
                                (6 . "A-law") (7 . "mu-law") (#xFFFE . "extensible")))
   (num-channels    :u16)
   (sample-rate     :u32)            ; Hz
   (byte-rate       :u32)            ; sample-rate * channels * bits-per-sample/8
   (block-align     :u16)            ; channels * bits-per-sample/8
   (bits-per-sample :u16)
   (subchunk2-id    (:string 4))     ; "data"
   (subchunk2-size  :u32))           ; number of bytes of audio data
 revision-hexdump:*templates*
 :key #'first :test #'string=)
