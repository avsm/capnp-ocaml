---
layout: post
title: "capnp-ocaml 2.0: The Road to Unembarrassing Performance"
---

In July I published the first release of
[capnp-ocaml](https://github.com/pelzlpj/capnp-ocaml), an OCaml
code generator plugin for the
[Cap'n Proto](http://kentonv.github.io/capnproto/) serialization
framework.  This release went out the door in a largely functional
state, but without much attention paid to the performance
characteristics of generated code. Feeling uncomfortable with this state
of affairs, I started work on an implementation of the \"suite of silly
benchmarks\" that ships with the Cap\'n Proto C++ compiler. My first run
of the \"carsales\" benchmark looked something like this:

![Early carsales benchmark]({{ site.baseurl }}/public/bench/orig-bar.png)

Oh dear.

I\'m under no illusion that OCaml code will be performance-competitive
with carefully-written C++; the language trades away a lot of control
over allocation and memory layout for comparable gains in safety and
expressiveness.  But I\'m used to seeing a performance degradation
[in the neighborhood of 3x to 6x](http://benchmarksgame.alioth.debian.org/u64/benchmark.php?test=all&lang=ocaml&lang2=gpp&data=u64).
Time to dig out the profiler and get to work.

     7.49%  caml_apply2
     4.64%  camlPres_impl__unsafe_get_ar_1040
     4.40%  camlRes__unsafe_get_1031
     3.23%  caml_page_table_lookup
     3.23%  caml_int64_compare
     2.74%  camlPres_impl__get_1055
     2.60%  camlCapnpRuntime__Message__get_uint8_2095
     2.52%  camlCapnpCarsales__random_car_2865
     2.33%  mark_slice
     1.89%  caml_apply3
     1.75%  camlCapnpRuntime__Message__get_uint16_2099
     1.72%  camlCapnpRuntime__Reader__get_bit_3495
     1.64%  camlFastRand__next_1011
     1.58%  camlCapnpCarsales__car_value_2779
     1.37%  camlCapnpRuntime__Message__set_uint8_2127
     1.34%  camlCapnpRuntime__Reader__get_uint16_3533
     1.24%  camlCapnpRuntime__Common__bounds_check_slice_exn_1807
     1.22%  camlCore_kernel__Int_conversions__is_in_range_1027
     1.12%  camlCapnpRuntime__Common__deref_pointer_2629
     1.12%  camlCapnpRuntime__Builder__get_data_field_7221
     1.10%  camlCapnpRuntime__Common__make_storage_2720
     1.10%  camlCapnpRuntime__Common__decode_pointer_1879
     1.05%  sweep_slice
     1.04%  camlCapnpRuntime__Builder__set_bit_7290
     ...

You know how great it is when your profiler trace resembles a textbook
example of the Pareto principle? This doesn\'t look like that. This is
the trace of a program that leaves a little performance on the table in
a lot of places. _Le sigh._

So I started chipping away. And here\'s what I did to the benchmark
timings over the course of about 40 commits:

![Carsales benchmark over time]({{ site.baseurl }}/public/bench/bench-commits.png)

## Benchmarking is Hard

Some of the poor performance had very little to do with Cap\'n Proto
serialization. The benchmark test cases perform some computations on
the data being serialized, both on the client side and on the server
side. Some of these computations happen to run a little slow in OCaml.

The benchmark uses an
[Xorshift RNG](http://en.wikipedia.org/wiki/Xorshift),
which is known to be a high-performance technique that yields \"pretty
good\" random bits--a natural choice for a benchmark that relies on random
numbers only for the generation of some interesting test data.

{% highlight c %}
static inline uint32_t nextFastRand() {
  static uint32_t x = 0x1d2acd47;
  static uint32_t y = 0x58ca3e14;
  static uint32_t z = 0xf563f232;
  static uint32_t w = 0x0bc76199;

  uint32_t tmp = x ^ (x << 11);
  x = y;
  y = z;
  z = w;
  w = w ^ (w >> 19) ^ tmp ^ (tmp >> 8);
  return w;
}
{% endhighlight %}

Early on, I could see that my
[OCaml implementation](https://github.com/pelzlpj/capnp-ocaml/blob/772b27e59ee827fb99c1cce91189e8768cca2cb4/src/benchmark/fastRand.ml)
of this RNG algorithm was not performing very well.
[Looking at the generated assembly]({{ site.baseurl }}/public/bench/xorshift-ocaml.html),
we can see that access to the persistent RNG state is kind of expensive
(a different OCaml data structure might improve the situation, but
ideally the RNG state should be completely decoupled from the OCaml heap).
Furthermore, the assembly for the Xorshift operations is bloated as an
unfortunate result of OCaml\'s tagged integer representation--operations
which are intended to compile down to single instructions get
transformed into more complicated sequences that preserve the integer
tag bits.  GCC generates
[something much more compact and straightforward]({{ site.baseurl }}/public/bench/xorshift-c.html)
for the C implementation.

The decision here was easy. The point of the benchmark is not to test
RNG performance; we care a lot more about testing the performance of the
capnp-ocaml serializers. The RNG code was trivially replaced with a C
extension that performs well. Similarly, OCaml-based implementations of
`strstr()` were not competitive for the short-string data set found in the
\"catrank\" benchmark, and
[calling straight into glibc](https://github.com/pelzlpj/capnp-ocaml/commit/1373bbc704ac909ac2748360babb0a088838ca63)
was an easy way to make the benchmark results more informative.

## Optimization Opportunities

Ignoring these uninteresting cases, what were the most effective
optimizations?

*   **Defunctorization.** OCaml
    [functors](http://caml.inria.fr/pub/docs/manual-ocaml/moduleexamples.html#sec20)
    provide a very nice framework for writing generic code, offering
    abstraction patterns similar to certain uses of C++ templates but
    without many of the corresponding disadvantages. Unfortunately, the
    implementation of OCaml functors resembles a record of closures, and
    defeats the compiler\'s inlining optimizations.

    This is a serious problem when the functorized code is performing
    operations like \"write a uint16 into a buffer at a specific
    offset.\" Such an operation should be completed very fast, which
    means that the computational overhead of performing an indirect call
    and loading the function environment from a closure record becomes
    significant.

    While I hope that future OCaml compiler releases may address this
    issue (of particular note,
    [Pierre Chambart\'s flambda work](http://www.ocamlpro.com/blog/2013/07/11/inlining-progress-report.html) sounds very interesting),
    at the moment the best solution available is to [manually
    defunctorize the
    code](https://github.com/pelzlpj/capnp-ocaml/commit/2298df4eeccd3e8124edc371a714410506a11ee2).
    In other words, we use the old-school C solution of implementing
    generic code via dirty `#include` hacks.

    This is an optional feature intended for use in
    performance-sensitive applications.  capnp-ocaml 2.0 generates
    *both* functors and defunctorized implementations suitable for
    use with a `camlp4` `INCLUDE` directive; client code can use either
    one.

*   **Elimination of unnecessary closures.** The OCaml compiler is
    sometimes described as _unsurprising_, meaning it does not perform
    many of the complex code transformations found in GCC, LLVM, GHC,
    and other highly-optimizing compilers. In many cases this is a good
    thing, as it means that OCaml programmers can have a very good
    intuitive feel for the costs associated with the code that they
    write. But in some cases, it means that one may need to sacrifice
    readability in order to achieve good performance.

    Idiomatic OCaml uses closures frequently. For example, closures are
    passed as arguments to higher-order functions when iterating over
    data structures, or may be constructed as \"nested functions\" to
    aid in expressing a larger algorithm.

    In general, OCaml will compile such code using indirect calls which
    access the environment via a closure record. The indirect calls can
    be expensive, and the additional GC pressure due to closure record
    allocation can also be expensive.  A compiler with more aggressive
    optimization passes might, in many circumstances, be able to compile
    a closure using an inlined function call which passes the
    environment in registers.  OCaml might get there some day, but not
    yet.

    The solution here involves transforming code to
    [avoid the use of higher-order functions](https://github.com/pelzlpj/capnp-ocaml/commit/c72a5640190e08075f84a3ca0c967e185780c4ad),
    and to
    [explicitly pass closure environments as function arguments](https://github.com/pelzlpj/capnp-ocaml/commit/94460e2d691620c1adeece2b5ae50e6d81149b56).

*   **Avoidance of `int64` primitive operations.** Cap\'n Proto uses a
    64-bit "word" as the basic allocation unit; objects are
    word-aligned, and [pointers to objects are stored in (usually) a
    single word](http://kentonv.github.io/capnproto/encoding.html). The
    natural way to deal with these pointers is to load them into an
    OCaml `int64` for ease of decoding the bitfields stored within these
    pointers.

    But OCaml uses a boxed representation of `int64`. Consequently,
    bitwise operations which _look_ inexpensive can involve unexpected
    loads and stores to and from the OCaml heap, as well as additional
    GC pressure
    ([`Int64.logand`](http://caml.inria.fr/pub/docs/manual-ocaml/libref/Int64.html),
    for example, will allocate heap storage to store the result).

    If OCaml is running on a 64-bit platform, the native OCaml (tagged)
    integer size is 63 bits. With careful use, these integers are large
    enough to carry out the bulk of the pointer decoding operations,
    significantly reducing the number of `int64` operations. Pointer
    dereferencing is a common operation when parsing message content, so
    [this optimization](https://github.com/pelzlpj/capnp-ocaml/blob/d113bb47ecb982d685d3e0fa0773d1c886a925fc/src/runtime/listPointer.ml#L49-L73)
    proves to be worthwhile.

*   **Reuse of buffers where possible.** OCaml heap allocation is cheap,
    but you pay for it at GC time.  Allocations in a hot loop
    [should be avoided if possible](https://github.com/pelzlpj/capnp-ocaml/commit/d6468e04608ba264788c9b4c62d91339eb70807c)
    (not because the allocation is expensive, but because it means
    you're creating a lot of garbage that will need to be dealt with).

*   **Loop Unrolling.** This is a textbook optimization which `ocamlopt`
    does not perform, as far as I know. For tight loops,
    [the difference can be measurable](https://github.com/pelzlpj/capnp-ocaml/commit/c3bda2d60771fa2a248f670d2af82725e585661f).

## Current Performance

So where do things sit now? Here is the current performance for the
\"carsales\" benchmark:
![Current carsales benchmark]({{ site.baseurl }}/public/bench/curr-carsales.png)
This probably requires some explanation:

* `object-none` performs a series of RPC-like operations by passing
  around capnp objects within a single process. This is testing the
  performance of the allocation algorithms and generated accessors.

* `bytes-none` carries out the same tasks, but additionally serializes
  and deserializes the objects to/from flat byte arrays.

* `pipe-none` splits the test into a client process and a server
  process, and sends the serialized data across a pipe. Requests
  are synchronous; the client waits for each response before sending
  the next request.

* `pipe-async-none` allows the client to send requests asynchronously.
  (The capnp-ocaml implementation is at a small disadvantage here;
  the C++ code uses separate reader and writer threads to manage the
  client-side asynchronous communication, but the OCaml code uses a
  single-threaded implementation that multiplexes over `read()` and
  `write()` with the aid of a `select()` loop.)

* The `-packed` variants use the Cap\'n Proto compression scheme known
  as
  \"[packing](http://kentonv.github.io/capnproto/encoding.html#packing)\".

The \"carsales\" benchmark exercises many primitive accessors, which is
clearly one of the weakest aspects of the OCaml implementation. capnp-ocaml
takes about five times as long as capnp-c++ across the board, which is
a large improvement over the initial release.

The \"catrank\" benchmark is heavy on accesses to string fields.
For ease of use in OCaml code, code for reading a string from a message
will always allocate a new OCaml string and copy data into it--there
are no generated accessors that perform a zero-copy access. At the first
release, this copy was slow due to the lack of a `memcpy()`-like
primitive.  This optimization has
[since been added](https://github.com/pelzlpj/capnp-ocaml/commit/dbccf430906d584fecf5ec88de4d346b229f6f88),
and consequently capnp-ocaml has somewhat stronger performance on \"catrank\":
![Current catrank benchmark]({{ site.baseurl }}/public/bench/curr-catrank.png)
This plot also makes clear the relatively poor performance of the OCaml
\"packing\" implementation relative to the C++ version. This is unlikely
to improve without the use of a C extension, which I would prefer to
avoid.

The \"eval\" benchmark constructs relatively short tree-structured
messages which make use of Cap\'n Proto\'s schema-level support for
sum types (which capnp-ocaml conveniently represents as OCaml variants).
Once again, capnp-ocaml does OK relative to capnp-c++:
![Current eval benchmark]({{ site.baseurl }}/public/bench/curr-eval.png)

## Conclusion

Idiomatic OCaml code tends to run pretty fast on average, but it can be
challenging to squeeze all the cycles out of performance-sensitive code.
The GC is a harsh mistress, freeing the programmer from memory
management concerns while offering only limited ways to work around
allocation-related performance issues.

capnp-ocaml is no longer embarrassingly slow, it is now merely
\"a bit slower than I would like.\" Some less formal tests suggested that
the current performance level is close to that of `bin_prot`, although
the message sizes are somewhat larger in the absence of compression.
