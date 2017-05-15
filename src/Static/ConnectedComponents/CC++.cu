/**
 * @author Federico Busato                                                  <br>
 *         Univerity of Verona, Dept. of Computer Science                   <br>
 *         federico.busato@univr.it
 * @date April, 2017
 * @version v2
 *
 * @copyright Copyright © 2017 cuStinger. All rights reserved.
 *
 * @license{<blockquote>
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * * Neither the name of the copyright holder nor the names of its
 *   contributors may be used to endorse or promote products derived from
 *   this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 * </blockquote>}
 */
#include "Static/ConnectedComponents/CC++.cuh"
#include <GraphIO/WCC.hpp>
namespace custinger_alg {

const color_t NO_COLOR = std::numeric_limits<color_t>::max();

//------------------------------------------------------------------------------
///////////////
// OPERATORS //
///////////////

struct Common {
    color_t*             d_colors;
    TwoLevelQueue<vid_t> queue;
    Common(color_t* d_colors_, TwoLevelQueue<vid_t> queue_) :
                                d_colors(d_colors_),
                                queue(queue_) {}
};

struct GiantCCOperator {
    color_t* d_colors;
    GiantCCOperator(color_t* d_colors_) : d_colors(d_colors_) {}

    __device__ __forceinline__
    bool operator()(const Vertex& src, const Edge& edge) {
        auto dst = edge.dst();
        if (d_colors[dst] == NO_COLOR) {
            d_colors[dst] = 0;
            return true;             // the vertex dst is active
        }
        return false;
    }
};

struct BuildVertexEnqueue {
    color_t*             d_colors;
    TwoLevelQueue<vid_t> queue;

    BuildVertexEnqueue(color_t* d_colors_, const TwoLevelQueue<vid_t>& queue_) :
                                d_colors(d_colors_),
                                queue(queue_) {}

    __device__ __forceinline__
    void operator()(const Vertex& src) {
        if (d_colors[src.id()] == NO_COLOR)
            queue.insert(src.id());
    }
};

struct BuildEdgeQueue {
    TwoLevelQueue<int2> queue;

    BuildEdgeQueue(const TwoLevelQueue<int2>& queue_) : queue(queue_) {}

    __device__ __forceinline__
    bool operator()(const Vertex& src, const Edge& edge) {
        if (src.id() > edge.dst())
            queue.insert(make_int2(src.id(), edge.dst()));
        return false;
    }
};

/*
struct Colorig : Common {
    Colorig(color_t* d_colors_, TwoLevelQueue<int2> queue_) :
                                Common(d_colors_, queue_) {}

    __device__ __forceinline__
    bool operator()(const int2& item) {
        auto src_color = d_colors[item.x];
        auto dst_color = d_colors[item.y];
        if (src_color > dst_color)
            d_colors[item.y] = d_colors[item.x];
        else if (src_color < dst_color)
            d_colors[item.x] = d_colors[item.y];
    }
};


struct ColorigAtomic : Common {
    EnqueueOperator(color_t* d_colors_, TwoLevelQueue<int2> queue_) :
                                Common(d_colors_, queue_) {}

    __device__ __forceinline__
    bool operator()(const int2& item) {
        auto src_color = d_colors[item.x];
        auto old_color = atomicMax(d_colors + item.y, src_color);
        if (src_color < old_color)
            atomicMax(d_colors + item.x, old_color);
        //d_colors[item.x] = old_color;
    W}
};*/

//------------------------------------------------------------------------------
////////
// CC //
////////

CC::CC(custinger::cuStinger& custinger) :  StaticAlgorithm(custinger),
                                           queue(custinger, true) {
    cuMalloc(d_colors, custinger.nV());
    reset();
}

CC::~CC() {
    cuFree(d_colors);
}

void CC::reset() {
    queue.clear();

    auto colors = d_colors;
    forAllnumV(custinger, [=] __device__ (int i){ colors[i] = NO_COLOR; } );
}

void CC::run() {
    auto max_vertex = custinger.max_degree_vertex();
    queue.insert(max_vertex);

    while (queue.size() > 0)
        queue.traverse_edges( GiantCCOperator(d_colors) );

    queue.clear();
    forAllVertices(custinger, BuildVertexEnqueue(d_colors, queue));
    queue.print2();

    TwoLevelQueue<int2> queue2(custinger);
    queue.traverse_edges( BuildEdgeQueue(queue2) );
    //while ()
    //    queue.traverse_edges( ColoringOperator() );
}

void CC::release() {
    cuFree(d_colors);
    d_colors = nullptr;
}

bool CC::validate() {
    using namespace graph;
    GraphStd<vid_t, eoff_t> graph(custinger.csr_offsets(), custinger.nV(),
                                  custinger.csr_edges(), custinger.nE());
    WCC<vid_t, eoff_t> wcc(graph);
    wcc.run();

    auto ratio_largest = xlib::per_cent(wcc.largest(), graph.nV());
    auto ratio_trivial = xlib::per_cent(wcc.num_trivial(),  graph.nV());
    std::cout << std::setprecision(1) << std::fixed
              << "\n        Number CC: " << xlib::format(wcc.size())
              << "\n       Largest CC: " << ratio_largest << " %"
              << "\n    N. Trivial CC: " << xlib::format(wcc.num_trivial())
              << "\n       Trivial CC: " << ratio_trivial << " %\n";

    wcc.print_histogram();

    auto color_match = new color_t[ wcc.size() ];
    std::fill(color_match, color_match + wcc.size(), NO_COLOR);

    auto d_results = new color_t[graph.nV()];
    cuMemcpyToHost(d_colors, graph.nV(), d_results);
    auto h_result = wcc.result();

    for (vid_t i = 0; i < graph.nV(); i++) {
        std::cout << h_result[i] << "\t" << d_results[i] << std::endl;
        /*if (color_match[ d_results[i] ] == NO_COLOR)
            color_match[ d_results[i] ] = h_result[i];
        else if (color_match[ d_results[i] ] != h_result[i])
            return false;*/
    }
    return true;
}

} // namespace custinger_alg