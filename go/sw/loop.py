"""Run versus_cpu() N times; used as the target for py-spy."""
import importlib.util
import sys

spec = importlib.util.spec_from_file_location('go_variant', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for _ in range(int(sys.argv[2])):
    mod.versus_cpu()
