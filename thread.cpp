#include <thread>
#include <iostream>
#include <ctime>
#include <cstdlib>
#include <chrono>
#include <mutex>
#include<csignal>
#include <vector>
#include <algorithm>
#include <cstring>   // for strcmp
#include <pthread.h> // for pthread_setschedparam, sched_param, SCHED_FIFO
#include <sys/mman.h>


// std::mutex cout_mtx;
// for proper shutdown handling
std::atomic<bool> shutdown_requested{false};

void handle_sigint(int sig){
    shutdown_requested = true;
}

struct VisionSample {
    double x,y;
    std::chrono::steady_clock::time_point timestamp;
    uint64_t seq;
};

struct DelaySample {
    size_t sample_delay; // total sample delay
    bool has_sample; //used to indicate if a valid sample is present for the histogram purposes. 
    size_t tick_duration_us; //control loop delay (what the control loop calculations take only) t1-t0
    size_t jitter_delay; // jitter in the control loop for wake up time, t3-t2
    std::chrono::steady_clock::time_point timestamp;
    uint64_t seq;
};

template <typename T>
class RingBuffer{
    public:
        RingBuffer(): head(0), tail(0), seq(0){}
        void write(T& value){
            int current = head.load();
            int next = (current+1)%3;
            value.seq= ++seq; 
            value.timestamp = std::chrono::steady_clock::now(); 
            buffer[next] = value;
            head.store(next,std::memory_order_release);

        }

        bool read(T& out){
            int current = head.load();
            int tail_int = tail.load();

            if (current == tail_int) {

                return false;
            }

            else {

                out= buffer[current];
                tail.store(current,std::memory_order_relaxed);

                return true;
            }



        }
    private:
        alignas(64) std::atomic<size_t> head;
        alignas(64) std::atomic<size_t> tail;
        uint64_t seq;
        T buffer[3];

};

int main(int argc, char* argv[]){
    bool use_rt = false;
    for (int i=0; i<argc; ++i){
        if (strcmp(argv[i], "--rt") == 0){
            // enable real-time mode
            use_rt = true;
        }
    }

    if (use_rt){
        if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0) {
            std::cerr << "mlockall FAILED: " << strerror(errno) << " (likely needs root)\n";
        } else {
            std::cerr << "memory locked, no page faults from swapping\n";
        }
    }

    std::signal(SIGINT, handle_sigint);
    RingBuffer<VisionSample> vision_ring; 
    RingBuffer<DelaySample> log_ring;

    srand(time(nullptr));
    std::thread t_vision([&vision_ring]{
        /*
        for (int i=0; i<3;++i){
            
            int random_value = rand()%51 +10;

            {
            std::lock_guard<std::mutex> lock(cout_mtx);
            std::cout << "vision" << std::endl;
            }

            std::this_thread::sleep_for(std::chrono::milliseconds(random_value));
        }*/
        VisionSample vision_value{0.0,0.0,std::chrono::steady_clock::now(),0};
        while(!shutdown_requested){

            int random_value = rand()%51 +10;
            std::this_thread::sleep_for(std::chrono::milliseconds(random_value));
            vision_value.x= rand()%100;
            vision_value.y= rand()%100;
            vision_ring.write(vision_value);
        }
       

    });

    std::thread t_control([&vision_ring, &log_ring]{
        /* for (int i=0; i<3;++i){

            {
            std::lock_guard<std::mutex> lock(cout_mtx);
            std::cout << "control" << std::endl;
            }

            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        } */
        VisionSample value{0.0,0.0,std::chrono::steady_clock::now(),0};
        bool new_value_bool;
        DelaySample delay_log{0,false,0,0, std::chrono::steady_clock::now(), 0};

        std::chrono::steady_clock::time_point sleep_till = std::chrono::steady_clock::now()+std::chrono::milliseconds(1);


        while(!shutdown_requested){
            std::chrono::steady_clock::time_point time= std::chrono::steady_clock::now();
 
            new_value_bool= vision_ring.read(value);

            if (new_value_bool){
                // std::cout << "vision pos: " << value.x << " " << value.y << std::endl;

                size_t sample_delay = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-value.timestamp).count();
                // writing to delay log ring buffer, for delay samples
                delay_log.sample_delay = sample_delay;
                delay_log.has_sample = true;
                
                // std::cout << "sample_delay: " << sample_delay << " microseconds" << std::endl;
            }
            else{
                // std::cout << "no new value" << std::endl;
                delay_log.has_sample = false;
            }

            delay_log.tick_duration_us= std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-time).count();

            // std::this_thread::sleep_for(std::chrono::milliseconds(1)-(std::chrono::steady_clock::now()-time));
            std::this_thread::sleep_until(sleep_till);

            size_t jitter_delay= std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-sleep_till).count();
            delay_log.jitter_delay = jitter_delay;

            sleep_till += std::chrono::milliseconds(1);

            log_ring.write(delay_log);

            }
        
    });

    if (use_rt) {
    sched_param param;
    param.sched_priority = 50;
    int result = pthread_setschedparam(t_control.native_handle(), SCHED_FIFO, &param);
    if (result != 0) {
        std::cerr << "SCHED_FIFO request FAILED: " << strerror(result) << "\n";
    } else {
        std::cerr << "SCHED_FIFO priority 50 applied to control thread\n";
    }
    }

    std::thread t_log([&log_ring]{
        DelaySample value{0, false, 0, 0, std::chrono::steady_clock::now(),0};
        bool new_value_bool;
        std::vector<size_t> sample_delays;
        std::vector<size_t> tick_durations;
        std::vector<size_t> jitter_delays;

        while(!shutdown_requested){
            new_value_bool= log_ring.read(value);

            if (new_value_bool){
                
                if (value.has_sample){
                    sample_delays.push_back(value.sample_delay);
                }
                tick_durations.push_back(value.tick_duration_us);
                jitter_delays.push_back(value.jitter_delay);
            }
        }

        auto report = [](std::string const& name, std::vector<size_t>& v){
            if (v.empty()){std::cout << name << " is empty" << std::endl; return;}
            
            std::sort(v.begin(), v.end());
            auto pct= [&](double percentile){return v[(size_t)((v.size()-1)*percentile)];};

            std::cout << name << ": n=" << v.size()
              << " min=" << v.front()
              << " p50=" << pct(0.50)
              << " p99=" << pct(0.99)
              << " max=" << v.back() << " (us)\n";
            

        };

        auto histogram = [](std::string const& name, std::vector<size_t>& v, int num_bins) {
            if (v.empty()) return;
            size_t mn = v.front(); // already sorted by report()
            size_t mx = v[(size_t)((v.size() - 1) * 0.99)]; // p99
            double width = (mx > mn) ? double(mx - mn) / num_bins : 1.0;
            std::vector<int> counts(num_bins, 0);
            for (size_t val : v) {
                int bin = (width > 0) ? int((val - mn) / width) : 0;
                if (bin >= num_bins) bin = num_bins - 1;
                counts[bin]++;
            }
            std::cout << "\n" << name << " histogram (us):\n";
            for (int i = 0; i < num_bins; i++) {
                size_t lo = mn + size_t(i * width);
                size_t hi = (i == num_bins - 1) ? v.back() : mn + size_t((i + 1) * width);
                std::cout << "  [" << lo << "-" << hi << "] "
                        << std::string(counts[i] * 60 / (int)v.size() + (counts[i] > 0 ? 1 : 0), '#')
                        << " " << counts[i] << "\n";
            }
        };

        report("sample_delay", sample_delays);
        report("tick_duration", tick_durations);
        report("jitter", jitter_delays);
        histogram("sample_delay", sample_delays, 12);
        histogram("tick_duration", tick_durations, 12);
        histogram("jitter", jitter_delays, 12);
        
    });

    t_vision.join();
    t_control.join();
    t_log.join();

    return 0;
}