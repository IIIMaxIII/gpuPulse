install
<pre id="command"><code>
wget -qO- https://github.com/IIIMaxIII/gpuPulse/raw/refs/heads/main/gpuPulse.tar.gz | tar -xz -C /hive/bin/ && grep -q "gpuPulse.sh" /hive/etc/crontab.root || echo "* * * * * /hive/bin/gpuPulse.sh >/dev/null 2>&1" >> /hive/etc/crontab.root</code></pre>
reboot


remove
<pre id="command"><code>rm -f /hive/bin/gpuPulse.* && sed -i '/gpuPulse.sh/d' /hive/etc/crontab.root</code></pre>
