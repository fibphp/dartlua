import 'dart:io';

main() async {
  await for (var f in new Directory("testcase").list().where((e) => e.path.endsWith(".lua"))) {
    print("Running ${f.path}...");
    var p = await Process.run("luadist/bin/lua52", [f.path]);
    if (p.stderr != "") {
      print(p.stdout);
      print(p.stderr);
      return 1;
    }
    await new File(f.path.replaceAll(".lua", ".txt")).writeAsString(p.stdout);
  }
}
