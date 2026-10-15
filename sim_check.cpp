#include <iostream>
#include <cassert>
#include <cmath>
#include <array>
#include "sim_robot.h"
#include "sensors.h"

int main() {
    // 1. make a robot that starts at time 0
    double start_time = 0.0;
    SimRobot test_robot(start_time);

    // 2. set its torque_cmd to 0.1
    double tau = 0.1;
    double b = test_robot.friction;
    double J = test_robot.inertia;
    test_robot.torque_cmd= tau;

    // 3. catch it up to 0.00603 seconds
    double elap_time= 0.00603;
    test_robot.catch_up(start_time+ elap_time);

    // 4. work out the exact speed from the formula
    double speed = test_robot.speed;
    double speed_exp=(tau/b)*(1-std::exp(-elap_time/(J/b)));
    double tol= 0.001*speed_exp;
    
    // 5. assert the robot's speed is within 0.1% of the exact one
    assert(std::fabs(speed-speed_exp)<=tol);

    // 6. do that with angle
    double angle_exp = (tau/b) * (elap_time - (J/b) * (1 - std::exp(-elap_time/(J/b))));
    double angle_tol = 0.02 * angle_exp;
    assert(std::fabs(test_robot.angle - angle_exp) <= angle_tol);

    // For angle in some range, angle -> counts -> angle 
    // should land within half a count of where it started.
    Encoder test_encoder;
    std::array<double, 3> angles ={0.005,-0.002,1}; 

    for (double orig_angle : angles){
        int temp = test_encoder.angle_to_counts(orig_angle);
        double conv_angle = test_encoder.counts_to_angle(temp);
        assert(std::abs(conv_angle - orig_angle) <= test_encoder.size_one_count/2); 

    }

       // Gyro test 1: randomness off, the reading is exactly truth + starting bias
    {
        Gyro g(0.0, 1);
        g.drift = 0.0;
        g.noise_std = 0.0;
        double reading = g.read_speed(0.001, 1.0);
        assert(std::fabs(reading - 1.02) <= 1e-12);
    }

    // Gyro test 2: spread of the bias after 1 s should be drift * sqrt(1 s)
    {
        const int seeds = 500;
        double sum_sq = 0.0;
        for (unsigned seed = 1; seed <= seeds; ++seed) {
            Gyro g(0.0, seed);
            g.noise_std = 0.0;                      // isolate the bias
            for (int i = 1; i <= 1000; ++i) g.read_speed(i * 0.001, 0.0);
            double wander = g.bias - 0.02;          // how far it moved from its start
            sum_sq += wander * wander;
        }
        double spread = std::sqrt(sum_sq / seeds);
        double expected = 0.005 * std::sqrt(1.0);
        assert(std::fabs(spread - expected) <= 0.15 * expected);
    }


    return 0;
}