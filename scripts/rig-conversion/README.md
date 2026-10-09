# Rig conversion data

`Sources/EQCore/RigConversionData.swift` holds the difference between a B&K 5128 and an IEC 711
reading of the same IEM: the median over every IEM measured on both rigs in two public squig.link
databases, aligned over 500 Hz–2 kHz and smoothed (1/6 octave below 4 kHz, widening to 1/2 octave
above 8 kHz, where individual IEMs differ by several dB).

To regenerate:

```sh
scripts/rig-conversion/download.sh /tmp/rig-data
swiftc -O Sources/EQCore/*.swift scripts/rig-conversion/compute.swift -o /tmp/rig-compute
/tmp/rig-compute /tmp/rig-data   # prints the curve and spread, writes "IEC 711 to B&K 5128.csv" and used.txt
```

Then convert the CSV to `RigConversionData.swift` at 24 points per octave (every second row).
