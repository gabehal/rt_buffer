#include "controllers.h"
#include "sim_robot.h"
#include "sensors.h"
#include "estimators.h"
#include <cassert>
#include <cmath>
#include <algorithm>

struct LoopResult{
    double end_angle; 
    double max_angle; 
    double angle_at_10ms;
    double settle_time;     // last time the joint was outside the 2% band
    double chatter;
    };


LoopResult run_loop(PDController& c, double target, double t_end, bool measured){
    SimRobot r(0.0);
    LoopResult result {0.0, 0.0, 0.0, 0.0, 0.0};
    Encoder enc;
    DiffEstimator est(0.0, 0); 

    const double band = 0.02 * target;
    double max_angle = 0.0, tq_min = 1e9, tq_max = -1e9;
    const int ticks= static_cast<int>(std::lround(t_end/0.001));


    for (int i=0; i<=ticks ; ++i){
        const double now = 0.001*i;
        r.catch_up(now);

        double angle = r.angle, speed= r.speed;
        if (measured){
            //this part is different from run_loop, because we assume that we get
            // the angle from the encoder counts, which is not entirely accurate since
            // each ecnoder count is some rad value. so we take true rad value
            // turn it to count, floor it, then turn it back to rad value
            int count = enc.angle_to_counts(r.angle);
            angle = enc.counts_to_angle(count);
            speed = est.update(now, count);
        }
        

        r.torque_cmd  = c.torque(target, angle, speed);

        //print last 10 torque values
        // if(i > ticks - 10) std::printf("%.2f\n", r.torque_cmd);
        
        max_angle = std::max(max_angle, r.angle);
        if (std::fabs(r.angle - target) > band) result.settle_time = now;

        if (i==10) result.angle_at_10ms = r.angle ; 
        if (i > ticks - 50) {
            tq_min = std::min(tq_min, r.torque_cmd);
            tq_max = std::max(tq_max, r.torque_cmd);
        }

    }
    result.end_angle = r.angle;
    result.max_angle = max_angle;
    result.chatter = tq_max - tq_min;


    return result;
}

int main() {

    std::printf("%-4s %-9s %10s %12s %12s %12s\n", "kd", "state", "overshoot%", "settle(ms)", "chatter(Nm)", "end_err");
    for (double kd : {1.0, 3.0, 6.0, 12.0}) {
        for (bool measured : {false, true}) {
            PDController c; c.kd = kd;
            LoopResult a = run_loop(c, 0.1, 0.2, measured);
            std::printf("%-4.0f %-9s %10.2f %12.1f %12.2f %12.6f\n", kd, measured ? "measured" : "true",
                (a.max_angle - 0.1) / 0.1 * 100, a.settle_time * 1e3, a.chatter, a.end_angle - 0.1);
        }
    }

    return 0;
}
