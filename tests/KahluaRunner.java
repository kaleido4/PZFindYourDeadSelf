import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Runs Lua files with Kahlua, the Lua VM Project Zomboid uses, taken from the
 * game's own projectzomboid.jar. Each file runs in a fresh environment that has
 * dofile(path) for loading mod files and mocks, and ROOT (the -Droot= property)
 * for building paths.
 *
 * The game jar is built for Java 25, so Kahlua is reached through reflection:
 * this file compiles with any JDK 17+ without the jar, and runs on the game's
 * bundled Java runtime (jre64) with the jar on the classpath.
 *
 * Kahlua reads stdlib.lua from the working directory, so run it from the game folder.
 * Usage: java -Droot=REPO -cp REPO/build;projectzomboid.jar KahluaRunner test1.lua [...]
 * (tests/run_tests.sh does this.)
 */
public class KahluaRunner {
    static Class<?> tableClass;
    static Method loadstring;
    static Method call;
    static Method rawset;

    public static void main(String[] args) throws Exception {
        Class<?> platformClass = Class.forName("se.krka.kahlua.j2se.J2SEPlatform");
        Class<?> platformInterface = Class.forName("se.krka.kahlua.vm.Platform");
        Class<?> threadClass = Class.forName("se.krka.kahlua.vm.KahluaThread");
        Class<?> javaFunction = Class.forName("se.krka.kahlua.vm.JavaFunction");
        tableClass = Class.forName("se.krka.kahlua.vm.KahluaTable");
        loadstring = Class.forName("se.krka.kahlua.luaj.compiler.LuaCompiler")
                .getMethod("loadstring", String.class, String.class, tableClass);
        call = threadClass.getMethod("call", Object.class, Object[].class);
        rawset = tableClass.getMethod("rawset", Object.class, Object.class);

        int failures = 0;
        for (String path : args) {
            Object platform = platformClass.getConstructor().newInstance();
            Object env = platformClass.getMethod("newEnvironment").invoke(platform);
            Object thread = threadClass.getConstructor(PrintStream.class, platformInterface, tableClass)
                    .newInstance(System.out, platform, env);
            threadClass.getField("debugOwnerThread").set(thread, Thread.currentThread());
            rawset.invoke(env, "ROOT", System.getProperty("root", "."));
            rawset.invoke(env, "dofile", Proxy.newProxyInstance(KahluaRunner.class.getClassLoader(),
                    new Class<?>[] { javaFunction }, (proxy, method, methodArgs) -> {
                        if (method.getName().equals("toString")) return "dofile";
                        if (method.getName().equals("hashCode")) return System.identityHashCode(proxy);
                        if (method.getName().equals("equals")) return proxy == methodArgs[0];
                        Object frame = methodArgs[0];
                        String file = null;
                        try {
                            file = (String) frame.getClass().getMethod("get", int.class).invoke(frame, 0);
                            Object frameThread = frame.getClass().getMethod("getThread").invoke(frame);
                            call.invoke(frameThread, compile(file, env), new Object[0]);
                            return 0;
                        } catch (InvocationTargetException e) {
                            throw new RuntimeException("dofile " + file + ": " + e.getCause(), e.getCause());
                        } catch (RuntimeException e) {
                            throw e;
                        } catch (Exception e) {
                            throw new RuntimeException("dofile " + file + ": " + e, e);
                        }
                    }));
            try {
                call.invoke(thread, compile(path, env), new Object[0]);
            } catch (InvocationTargetException e) {
                failures++;
                System.out.println("FAIL " + path + ": " + rootMessage(e) + " (last line " + threadClass.getField("currentLine").get(thread) + ")");
            }
        }
        if (failures > 0) {
            System.out.println(failures + " test file(s) failed");
            System.exit(1);
        }
        System.out.println("All test files passed");
    }

    static Object compile(String path, Object env) throws Exception {
        return loadstring.invoke(null, Files.readString(Path.of(path)), path, env);
    }

    static String rootMessage(Throwable e) {
        while (e.getCause() != null) e = e.getCause();
        return String.valueOf(e.getMessage());
    }
}
