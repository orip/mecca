module mecca.lib.time;

public import std.datetime;
import mecca.lib.divide: S64Divisor;
public import mecca.platform.x86: readTSC;


struct TscTimePoint {
    private enum HECTONANO = 10_000_000;
    enum min = TscTimePoint(long.min);
    enum zero = TscTimePoint(0);
    enum max = TscTimePoint(long.max);

    static shared immutable long cyclesPerSecond;
    static shared immutable long cyclesPerMsec;
    static shared immutable long cyclesPerUsec;
    alias frequency = cyclesPerSecond;

    static shared immutable S64Divisor cyclesPerSecondDivisor;
    static shared immutable S64Divisor cyclesPerMsecDivisor;
    static shared immutable S64Divisor cyclesPerUsecDivisor;
    /* thread local */ static ubyte refetchInterval;
    /* thread local */ static ubyte fetchCounter;
    /* thread local */ static TscTimePoint lastTsc;

    long cycles;

    static TscTimePoint softNow() nothrow @nogc @safe {
        if (fetchCounter < refetchInterval) {
            fetchCounter++;
            lastTsc.cycles++;
            return lastTsc;
        }
        else {
            return now();
        }
    }
    static TscTimePoint now() nothrow @nogc @safe {
        pragma(inline, true);
        lastTsc.cycles = readTSC();
        fetchCounter = 0;
        return lastTsc;
    }

    shared static this() {
        import std.exception;
        import core.sys.posix.time;
        import std.file: readText;
        import std.string;

        // the main thread actually performs RDTSC 1 in 10 calls
        refetchInterval = 10;

        version (linux) {
        }
        else {
            static assert (false, "a linux system is required");
        }

        enforce(readText("/proc/cpuinfo").indexOf("constant_tsc") >= 0, "constant_tsc not supported");

        timespec sleepTime = timespec(0, 200_000_000);
        timespec t0, t1;

        auto rc1 = clock_gettime(CLOCK_MONOTONIC, &t0);
        auto cyc0 = readTSC();
        auto rc2 = nanosleep(&sleepTime, null);
        auto rc3 = clock_gettime(CLOCK_MONOTONIC, &t1);
        auto cyc1 = readTSC();

        errnoEnforce(rc1 == 0, "clock_gettime");
        errnoEnforce(rc2 == 0, "nanosleep");   // we hope we won't be interrupted by a signal here
        errnoEnforce(rc3 == 0, "clock_gettime");

        auto nsecs = (t1.tv_sec - t0.tv_sec) * 1_000_000_000UL + (t1.tv_nsec  - t0.tv_nsec);
        cyclesPerSecond = cast(long)((cyc1 - cyc0) / (nsecs / 1E9));
        cyclesPerMsec = cyclesPerSecond / 1_000;
        cyclesPerUsec = cyclesPerSecond / 1_000_000;

        cyclesPerSecondDivisor = S64Divisor(cyclesPerSecond);
        cyclesPerMsecDivisor = S64Divisor(cyclesPerMsec);
        cyclesPerUsecDivisor = S64Divisor(cyclesPerUsec);

        now();
    }

    static auto fromNow(Duration dur) @nogc {
        return now + toCycles(dur);
    }
    static long toCycles(Duration dur) @nogc @trusted nothrow {
        long hns = dur.total!"hnsecs";
        return (hns / HECTONANO) * cyclesPerSecond + ((hns % HECTONANO) * cyclesPerSecond) / HECTONANO;
    }
    static long toCycles(string unit)(long n) @nogc @safe nothrow {
        static if (unit == "usecs") {
            return n * cyclesPerUsec;
        } else static if (unit == "msecs") {
            return n * cyclesPerMsec;
        } else static if (unit == "seconds") {
            return n * cyclesPerSecond;
        }
    }
    static Duration toDuration(long cycles) @nogc @safe nothrow {
        return hnsecs((cycles / cyclesPerSecond) * HECTONANO + ((cycles % cyclesPerSecond) * HECTONANO) / cyclesPerSecond);
    }
    Duration toDuration() const @safe nothrow {
        return hnsecs((cycles / cyclesPerSecond) * HECTONANO + ((cycles % cyclesPerSecond) * HECTONANO) / cyclesPerSecond);
    }
    static long toUsecs(long cycles) @nogc @safe nothrow {
        return cycles / cyclesPerUsecDivisor;
    }
    long toUsecs() const @nogc @safe nothrow {
        return cycles / cyclesPerUsecDivisor;
    }
    static long toMsecs(long cycles) @nogc @safe nothrow {
        return cycles / cyclesPerMsecDivisor;
    }
    long toMsecs() const @nogc @safe nothrow {
        return cycles / cyclesPerMsecDivisor;
    }

    int opCmp(TscTimePoint rhs) const @nogc @safe nothrow {
        return (cycles > rhs.cycles) ? 1 : ((cycles < rhs.cycles) ? -1 : 0);
    }
    bool opEquals()(TscTimePoint rhs) const @nogc @safe nothrow {
        return cycles == rhs.cycles;
    }

    TscTimePoint opBinary(string op: "+")(long cycles) const @nogc @safe nothrow {
        return TscTimePoint(this.cycles + cycles);
    }
    TscTimePoint opBinary(string op: "+")(Duration dur) const @nogc @safe nothrow {
        return TscTimePoint(cycles + toCycles(dur));
    }

    Duration opBinary(string op: "-")(long cycles) const @nogc @safe nothrow {
        return TscTimePoint.toDuration(this.cycles - cycles);
    }
    Duration opBinary(string op: "-")(TscTimePoint rhs) const @nogc @safe nothrow {
        return TscTimePoint.toDuration(cycles - rhs.cycles);
    }
    TscTimePoint opBinary(string op: "-")(Duration dur) const @nogc @safe nothrow {
        return TscTimePoint(cycles - toCycles(dur));
    }

    ref auto opOpAssign(string op)(Duration dur) @nogc if (op == "+" || op == "-") {
        mixin("cycles " ~ op ~ "= toCycles(dur);");
        return this;
    }
    ref auto opOpAssign(string op)(long cycles) @nogc if (op == "+" || op == "-") {
        mixin("this.cycles " ~ op ~ "= cycles;");
        return this;
    }

    long diff(string units)(TscTimePoint rhs) @nogc if (units == "usecs" || units == "msecs" || units == "seconds" || units == "cycles") {
        static if (units == "usecs") {
            return (cycles - rhs.cycles) / cyclesPerUsecDivisor;
        }
        else static if (units == "msecs") {
            return (cycles - rhs.cycles) / cyclesPerMsecDivisor;
        }
        else static if (units == "seconds") {
            return (cycles - rhs.cycles) / cyclesPerSecondDivisor;
        }
        else static if (units == "cycles") {
            return (cycles - rhs.cycles);
        }
        else {
            static assert (false, units);
        }
    }

    long to(string unit)() @nogc @safe nothrow {
        return toDuration.total!unit();
    }
}

unittest {
    auto t0 = TscTimePoint.now;
    assert (t0.cycles > 0);
    assert (TscTimePoint.cyclesPerSecond > 1_000_000);
}

struct Timeout {
    enum Timeout elapsed = Timeout(TscTimePoint.min);
    enum Timeout infinite = Timeout(TscTimePoint.max);

    TscTimePoint expiry;

    this(TscTimePoint expiry) {
        this.expiry = expiry;
    }
    this(Duration dur, TscTimePoint now = TscTimePoint.now) @safe @nogc {
        if (dur == Duration.max) {
            this.expiry = TscTimePoint.max;
        }
        else {
            this.expiry = now + dur;
        }
    }
}




